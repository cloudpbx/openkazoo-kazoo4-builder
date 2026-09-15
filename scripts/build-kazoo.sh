#!/usr/bin/env bash
# build-kazoo.sh — build Kazoo 4.4 and wrap it into a `kazoo` .deb.
# Ports kazoo-deploy build-packages.yml L247-376.
#
# Uses `rebar3 compile && rebar3 tar` on the DEFAULT profile (as the playbook
# does): this sidesteps the openkazoo Makefile's `git describe --tags` release
# gate entirely, so no upstream tags are required and the source Makefile is
# left unmodified. Output tarball lands in _build/default/rel/kazoo/*.tar.gz.
# rebar.config is patched to include_erts=false so the deb depends on the
# separately-built `erlang` package rather than bundling ERTS.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Idempotent replace-or-insert of {include_erts, false} in a rebar.config.
# Implemented without `sed -i` / `\n`-in-replacement so it is portable across
# GNU sed (Debian build container) and BSD sed (macOS dev hosts); awk does the
# after-the-{relx, [ insert. Semantics match the original playbook sed.
patch_include_erts() {
  local f="$1" out="$1.new"
  if grep -q 'include_erts' "$f"; then
    # tolerate whitespace variations so a reformat upstream can't silently no-op
    # (which would leave ERTS bundled, breaking the erlang-dependency model).
    sed -E 's/\{include_erts,[[:space:]]*true\}/{include_erts, false}/g' "$f" > "$out"
  else
    awk '{ print }
         /\{relx,[[:space:]]*\[/ && !ins { print "  {include_erts, false},"; ins = 1 }' "$f" > "$out"
  fi
  mv "$out" "$f"
}

# The ERTS-provided applications upstream declares as {App, none} in the relx
# release. `none` means include but neither load nor start, which is correct
# only while include_erts is true, because the bundled ERTS boot supplies them.
# patch_include_erts flips include_erts to false, so without this they end up
# neither bundled nor started: the boot script omits 7 of its starts, hackney
# and couchbeam cannot start, kazoo_data never starts, and no kapp ever starts.
# The visible symptom is `sup kapps_controller running_apps` blaming rabbitmq
# and BigCouch connectivity, which sends you chasing the wrong thing.
#
# os_mon is deliberately NOT in this list. It is ERTS-provided and declared
# none, but the known-good release does not start it either, so restoring it
# would add a start the working deployment never had.
ERTS_APPS_TO_START='crypto ssl public_key asn1 compiler runtime_tools syntax_tools'

# Rewrite {App, none} -> App for the apps above, leaving every other `none`
# alone. The ~38 kazoo kapps are legitimately none: kapps_controller starts
# them on demand, so starting them at boot would ignore per-node config.
patch_erts_app_load_types() {
  local f="$1" out="$1.new" app
  cp "$f" "$out"
  for app in $ERTS_APPS_TO_START; do
    # Anchored on the exact tuple so a kapp sharing a name prefix is untouched.
    sed -E "s/\{$app,[[:space:]]*none\}/$app/g" "$out" > "$out.t" && mv "$out.t" "$out"
  done
  mv "$out" "$f"
}

# synth_version <branch> <yyyymmdd> <shortsha> -> 4.4.0~<branch>.<date>.<sha>
synth_version() { echo "4.4.0~${1}.${2}.${3}"; }

# Allow sourcing for tests without executing the build.
[ "${1:-}" = "--lib-only" ] && return 0

ROOT="$(repo_root)"
CODENAME="$(codename_for "${DISTRO:?}")"
OUT="$ROOT/build/out/$CODENAME"
SRC="$ROOT/build/kazoo-src"
STAGE="$ROOT/build/kazoo-deb"
ARCH="$(arch_normalize "$(uname -m)")"
mkdir -p "$OUT"

echo ">> Cloning cloudpbx/openkazoo@${KAZOO_VERSION:?}"
rm -rf "$SRC"
git clone --depth 1 --branch "$KAZOO_VERSION" \
  https://github.com/cloudpbx/openkazoo.git "$SRC"

SHORTSHA="$(git -C "$SRC" rev-parse --short=8 HEAD)"
TODAY="$(date -u +%Y%m%d)"
PKG_VERSION="$(synth_version "$KAZOO_VERSION" "$TODAY" "$SHORTSHA")-${PKG_REVISION:?}~${CODENAME}"
DEB="$OUT/kazoo_${PKG_VERSION}_${ARCH}.deb"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

echo ">> Patching include_erts=false"
patch_include_erts "$SRC/rebar.config"
echo ">> Restoring load types for ERTS apps the unbundled release must start"
patch_erts_app_load_types "$SRC/rebar.config"

export PATH="/usr/local/lib/erlang/bin:$PATH"
echo ">> rebar3 compile (hard gate)"
( cd "$SRC" && rebar3 compile )
echo ">> rebar3 tar"
( cd "$SRC" && rebar3 tar )

TARBALL="$(find "$SRC/_build/default/rel/kazoo" -maxdepth 1 -name '*.tar.gz' | head -1)"
[ -n "$TARBALL" ] || die "no release tarball in _build/default/rel/kazoo"

echo ">> Packaging kazoo deb: $DEB"
rm -rf "$STAGE"; mkdir -p "$STAGE/opt/kazoo"
tar -xzf "$TARBALL" -C "$STAGE/opt/kazoo"

REL_DIR="$STAGE/opt/kazoo/releases/0.0.0"
# relx names the release boot script start.boot, but the runner execs
# `-boot <reldir>/kazoo`, so the release needs that name too. Copy rather than
# symlink so dpkg owns a real file and an in-place upgrade replaces it.
[ -f "$REL_DIR/start.boot" ] || die "relx emitted no start.boot in $REL_DIR"
cp "$REL_DIR/start.boot" "$REL_DIR/kazoo.boot"

# Hard gate on the boot script's contents. Every deb before this shipped a
# script that started neither crypto nor ssl and could not boot, and `rebar3
# tar` exits 0 regardless, so nothing upstream of here catches it.
echo ">> Gating boot script starts the ERTS apps"
( cd "$REL_DIR" && erl -noshell -eval '
    {ok, Bin} = file:read_file("kazoo.boot"),
    {script, {Name, _Vsn}, Instrs} = binary_to_term(Bin),
    Started = [A || {apply, {application, start_boot, [A | _]}} <- Instrs],
    Required = [crypto, ssl, public_key, asn1, compiler, runtime_tools, syntax_tools, kazoo],
    Missing = [A || A <- Required, not lists:member(A, Started)],

    %% Every started application must have its declared dependencies started
    %% before it. systools only checks that deps are *included*, not started,
    %% so a load-only dep produces a script that generates cleanly and then
    %% dies at runtime. goldrush is the live example: it declares syntax_tools
    %% and compiler, which ship as load-only. Asserting the invariant beats
    %% patching one app by name, which is what a dependency-order regression
    %% in any other app would need next.
    Specs = [{A, D} || {apply, {application, load, [{application, A, P} | _]}} <- Instrs,
                       lists:member(A, Started), {applications, D} <- P],
    Rank = fun(A) -> length(lists:takewhile(fun(E) -> E =/= A end, Started)) end,
    OutOfOrder = [{A, Dep} || {A, Deps} <- Specs, Dep <- Deps,
                              lists:member(Dep, Started) =:= false
                                orelse Rank(Dep) > Rank(A)],

    case {Missing, OutOfOrder} of
      {[], []} ->
        io:format("   ~s boot script starts ~p applications, dependency order clean~n",
                  [Name, length(Started)]),
        halt(0);
      _ ->
        io:format("   FATAL: never started ~p~n   FATAL: dependency violations ~p~n",
                  [Missing, OutOfOrder]),
        halt(1)
    end.' ) || die "boot script gate failed — check the relx load types in rebar.config"

write_deb_control "$STAGE" kazoo "$PKG_VERSION" "$ARCH" \
  "Kazoo 4.4 UCaaS platform (built against Erlang/OTP ${OTP_VERSION}, include_erts=false)" \
  "erlang (>= 1:${OTP_VERSION%%.*})"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
