#!/usr/bin/env bash
# publish.sh — assemble a signed, multi-arch pooled apt repo under build/repo/.
# Inputs: build/out/<codename>/*.deb (any component, amd64 and/or arm64).
# Output: build/repo/{pool,dists}/... + build/repo/pubkey.asc
# Adapted from openkazoo-kazoo5-builder/scripts/publish.sh (reprepro), extended
# to Architectures: amd64 arm64 and dropping the yum path.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The supported Debian releases (codenames). One reprepro distribution each.
DISTRO_CODENAMES=(bullseye bookworm)

write_distributions() {
  local apt_dir="$1" fpr="$2" cn
  mkdir -p "$apt_dir/conf"
  : > "$apt_dir/conf/distributions"
  for cn in "${DISTRO_CODENAMES[@]}"; do
    cat >> "$apt_dir/conf/distributions" <<EOF
Origin: openkazoo
Label: openkazoo-kazoo4-builder
Suite: stable
Codename: $cn
Architectures: amd64 arm64
Components: main
Description: Community-built Kazoo 4.4 stack for Debian $cn
SignWith: $fpr

EOF
  done
}

# published_rows <apt_dir> -> "codename<TAB>package<TAB>version<TAB>arch,arch"
# Reads reprepro's own index so the page reports what shipped, not what we hoped
# would ship. `reprepro list` prints "<codename>|<component>|<arch>: <pkg> <ver>";
# the version's epoch colon has no trailing space, so splitting on ": " is safe.
published_rows() {
  local apt_dir="$1" cn
  for cn in "${DISTRO_CODENAMES[@]}"; do
    reprepro -b "$apt_dir" list "$cn" 2>/dev/null
  done | awk '
    {
      sep = index($0, ": ")
      if (sep == 0) next
      split(substr($0, 1, sep - 1), h, "|")
      split(substr($0, sep + 2), r, " ")
      key = h[1] "\t" r[1] "\t" r[2]
      if (!(key in seen)) { order[++n] = key; seen[key] = "" }
      arches[key] = arches[key] (arches[key] == "" ? "" : ",") h[3]
    }
    END { for (i = 1; i <= n; i++) print order[i] "\t" arches[order[i]] }
  ' | sort
}

# write_index_html <repo_dir> <apt_dir> -> landing page on stdout
write_index_html() {
  local repo_dir="$1" apt_dir="$2" cn pkg ver arches
  local pkg_rows="" suite_rows=""

  while IFS=$'\t' read -r cn pkg ver arches; do
    [ -n "$cn" ] || continue
    pkg_rows+="<tr><td><code>$pkg</code></td><td>$cn</td><td><code>$ver</code></td><td>${arches//,/, }</td></tr>"$'\n'
  done < <(published_rows "$apt_dir")

  for cn in "${DISTRO_CODENAMES[@]}"; do
    local rel="Debian 12" ; [ "$cn" = bullseye ] && rel="Debian 11"
    suite_rows+="<tr><td>$rel</td><td><code>$cn</code></td><td>amd64, arm64</td></tr>"$'\n'
  done

  cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>openkazoo-kazoo4-builder apt repository</title>
<style>
  :root { color-scheme: light dark; --fg:#1a1a1a; --bg:#fff; --mut:#5a5a5a;
          --line:#d8d8d8; --code:#f4f4f4; --accent:#0a5; }
  @media (prefers-color-scheme: dark) {
    :root { --fg:#e6e6e6; --bg:#151515; --mut:#a0a0a0; --line:#333; --code:#1f1f1f; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:2rem 1rem 4rem; background:var(--bg); color:var(--fg);
         font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
  main { max-width: 52rem; margin: 0 auto; }
  h1 { font-size:1.6rem; margin:0 0 .25rem; }
  h2 { font-size:1.15rem; margin:2.25rem 0 .6rem; border-bottom:1px solid var(--line); padding-bottom:.3rem; }
  .sub { color:var(--mut); margin:0 0 1.5rem; }
  code { background:var(--code); padding:.12em .35em; border-radius:3px;
         font:0.88em/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  pre { background:var(--code); padding:1rem; border-radius:6px; overflow-x:auto; }
  pre code { background:none; padding:0; }
  table { border-collapse:collapse; width:100%; margin:.5rem 0; display:block; overflow-x:auto; }
  th,td { text-align:left; padding:.45rem .7rem; border-bottom:1px solid var(--line); white-space:nowrap; }
  th { font-size:.82rem; text-transform:uppercase; letter-spacing:.04em; color:var(--mut); }
  .note { border-left:3px solid var(--accent); padding:.6rem 0 .6rem 1rem; margin:1rem 0; color:var(--mut); }
  a { color:inherit; }
  footer { margin-top:3rem; color:var(--mut); font-size:.9rem; }
</style>
</head>
<body>
<main>

<h1>openkazoo-kazoo4-builder</h1>
<p class="sub">Community-built Debian packages for the Kazoo 4.4 telephony stack.
This host serves the signed apt repository.</p>

<h2>Targets</h2>
<table>
  <thead><tr><th>Release</th><th>Codename</th><th>Architectures</th></tr></thead>
  <tbody>
$suite_rows  </tbody>
</table>

<h2>Packages</h2>
<table>
  <thead><tr><th>Package</th><th>Suite</th><th>Version</th><th>Architectures</th></tr></thead>
  <tbody>
$pkg_rows  </tbody>
</table>

<h2>Install</h2>
<p>The snippet detects your codename from <code>/etc/os-release</code>.</p>
<pre><code>curl -fsSL https://cloudpbx.github.io/openkazoo-kazoo4-builder/pubkey.asc \\
  | sudo tee /usr/share/keyrings/openkazoo.asc &gt; /dev/null

. /etc/os-release   # sets \$VERSION_CODENAME (bullseye or bookworm)
echo "deb [signed-by=/usr/share/keyrings/openkazoo.asc] \\
https://cloudpbx.github.io/openkazoo-kazoo4-builder/debian \${VERSION_CODENAME} main" \\
  | sudo tee /etc/apt/sources.list.d/openkazoo.list

sudo apt-get update
sudo apt-get install -y kazoo freeswitch kamailio</code></pre>
<p><code>erlang</code> is pulled in automatically as a dependency of <code>kazoo</code>.
Signing key: <a href="pubkey.asc">pubkey.asc</a>.</p>

<h2>Notes</h2>
<div class="note">
<p><strong>No video support.</strong> FreeSWITCH is built without VP8/VP9
(<code>--disable-libvpx --disable-libyuv</code>). Audio telephony, including calls,
media proxy, IVR, voicemail and fax, is fully supported.</p>
<p><strong>Erlang/OTP 26 is a ceiling, not just a pin.</strong> Kazoo 4.4 does not run on
newer OTP. Debian 11 ships OTP 23 and Debian 12 ships OTP 25, so the stock
<code>erlang</code> is too old on both targets; this repository ships its own.</p>
<p>These are community builds with no commercial support. Service orchestration
(systemd units, config, clustering) is handled by your deployment tooling, not
by these packages.</p>
</div>

<footer>
Source and docs:
<a href="https://github.com/cloudpbx/openkazoo-kazoo4-builder">github.com/cloudpbx/openkazoo-kazoo4-builder</a>.
Generated by <code>scripts/publish.sh</code>.
</footer>

</main>
</body>
</html>
EOF
}

[ "${1:-}" = "--lib-only" ] && return 0

ROOT="$(repo_root)"
OUT="${OUT_DIR_OVERRIDE:-$ROOT/build/out}"
REPO="$ROOT/build/repo"; APT="$REPO/debian"

# debs live under build/out/<codename>/ (one dir per Debian release).
DEBS=()
while IFS= read -r -d '' deb; do DEBS+=("$deb"); done \
  < <(find "$OUT" -type f -name '*.deb' -print0)
[ "${#DEBS[@]}" -gt 0 ] || die "no packages under $OUT; run 'make build' first"

if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
  TMP_GNUPGHOME="$(mktemp -d)"; trap 'rm -rf "$TMP_GNUPGHOME"' EXIT
  chmod 700 "$TMP_GNUPGHOME"; export GNUPGHOME="$TMP_GNUPGHOME"
  echo "$GPG_PRIVATE_KEY" | gpg --batch --import 2>&1 | tail -3
fi
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || die "no GPG key available"

mkdir -p "$REPO"
gpg --armor --export "$FPR" > "$REPO/pubkey.asc"
write_distributions "$APT" "$FPR"
# Route each deb into the reprepro distribution matching its codename dir.
for cn in "${DISTRO_CODENAMES[@]}"; do
  shopt -s nullglob; cdebs=("$OUT/$cn"/*.deb); shopt -u nullglob
  for deb in "${cdebs[@]}"; do
    echo ">> reprepro includedeb $cn: $deb"
    # -S/-P provide a default section/priority if a deb's control lacks them,
    # so includedeb never fails with "No section given" (the control now sets
    # them, but this keeps publish robust to any future package).
    reprepro -S comm -P optional -b "$APT" includedeb "$cn" "$deb"
  done
done

cat > "$REPO/README.md" <<'EOF'
# openkazoo-kazoo4-builder package repository
This `gh-pages` branch hosts the apt repository for the Kazoo 4.4 stack.
See docs/INSTALL.md in the main branch. Public signing key: `pubkey.asc`.
EOF

# The Pages deploy sets .nojekyll, so README.md is never rendered — without an
# index.html the site root serves GitHub's 404 to anyone who trims /debian off
# the apt URL. Emit the landing page from what reprepro actually published, so
# the advertised targets can't drift from the packages on disk.
write_index_html "$REPO" "$APT" > "$REPO/index.html"
echo ">> Published under: $REPO"
