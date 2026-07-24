#!/usr/bin/env bash
# build-kamailio.sh — build Kamailio 5.8.8 into a `kamailio` .deb.
# Ports kazoo-deploy build-packages.yml L614-792 (arch-parameterized).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"; B="$ROOT/build"
CODENAME="$(codename_for "${DISTRO:?}")"
OUT="$ROOT/build/out/$CODENAME"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${KAMAILIO_VERSION:?}-${PKG_REVISION:?}~${CODENAME}"
DEB="$OUT/kamailio_${VER}_${ARCH}.deb"
mkdir -p "$OUT"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

echo ">> Cloning kamailio ${KAMAILIO_VERSION}"
rm -rf "$B/kamailio"
git clone --depth 1 --branch "$KAMAILIO_VERSION" \
  https://github.com/kamailio/kamailio.git "$B/kamailio"

echo ">> Building kamailio (~30 min)"
( cd "$B/kamailio" \
  && make FLAVOUR=kamailio include_modules="db_mysql db_postgres tls kazoo rabbitmq" PREFIX=/usr cfg \
  && make -j"$(nproc)" \
  && make install )

echo ">> Packaging kamailio deb: $DEB"
STAGE="$B/kamailio-deb"; rm -rf "$STAGE"
mkdir -p "$STAGE/usr/sbin"
cp -a /usr/sbin/kamailio "$STAGE/usr/sbin/"
# `make cfg PREFIX=/usr` installs modules under /usr/lib64 on 64-bit (not
# /usr/lib) and default config under /usr/etc. Preserve whichever paths the
# build actually used — the binary's compiled-in module search path must match.
for d in /usr/lib64/kamailio /usr/lib/kamailio /usr/etc/kamailio /etc/kamailio; do
  [ -d "$d" ] || continue
  dest="$STAGE$(dirname "$d")"
  mkdir -p "$dest"
  cp -a "$d" "$dest/"
done
# Gate: a kamailio package without its modules is useless (silent ecallmgr/SIP
# failures). Fail loudly rather than shipping a binary-only deb.
find "$STAGE" -path '*kamailio*' -name '*.so' -print -quit | grep -q . \
  || die "no kamailio modules staged — check install LIBDIR (expected /usr/lib64/kamailio/modules)"
write_deb_control "$STAGE" kamailio "$VER" "$ARCH" \
  "Kamailio ${KAMAILIO_VERSION} SIP proxy (db_mysql db_postgres tls kazoo rabbitmq)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
