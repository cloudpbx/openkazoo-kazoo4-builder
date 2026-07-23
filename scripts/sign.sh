#!/usr/bin/env bash
# sign.sh — GPG-sign every built .deb with debsigs (origin role).
# Key source priority: $GPG_PRIVATE_KEY (CI) -> $GNUPGHOME (local).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"; OUT="$ROOT/build/out"

if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
  TMP_GNUPGHOME="$(mktemp -d)"; trap 'rm -rf "$TMP_GNUPGHOME"' EXIT
  chmod 700 "$TMP_GNUPGHOME"; export GNUPGHOME="$TMP_GNUPGHOME"
  if [ -n "${GPG_PASSPHRASE:-}" ]; then
    echo "$GPG_PRIVATE_KEY" | gpg --batch --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" --import 2>&1 | tail -3
  else
    echo "$GPG_PRIVATE_KEY" | gpg --batch --import 2>&1 | tail -3
  fi
elif [ -n "${GNUPGHOME:-}" ] && [ -d "${GNUPGHOME:-/nonexistent}" ]; then
  echo ">> Using local GNUPGHOME=$GNUPGHOME"
else
  die "no key source: set GPG_PRIVATE_KEY or GNUPGHOME"
fi

FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || die "no secret key found in keyring"
echo ">> Signing with $FPR"

shopt -s nullglob
DEBS=("$OUT"/*.deb); shopt -u nullglob
[ "${#DEBS[@]}" -gt 0 ] || die "no .deb files in $OUT"
for deb in "${DEBS[@]}"; do
  echo ">> debsigs sign: $deb"
  debsigs --sign=origin --default-key="$FPR" "$deb"
done
echo ">> Signing complete."
