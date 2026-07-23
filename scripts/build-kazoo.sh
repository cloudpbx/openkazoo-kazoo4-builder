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
write_deb_control "$STAGE" kazoo "$PKG_VERSION" "$ARCH" \
  "Kazoo 4.4 UCaaS platform (built against Erlang/OTP ${OTP_VERSION}, include_erts=false)" \
  "erlang (>= ${OTP_VERSION%%.*})"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
