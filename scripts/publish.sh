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
echo ">> Published under: $REPO"
