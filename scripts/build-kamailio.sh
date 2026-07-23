#!/usr/bin/env bash
# build-kamailio.sh — build Kamailio 5.8.8 into a `kamailio` .deb.
# Ports kazoo-deploy build-packages.yml L614-792 (arch-parameterized).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"; OUT="$ROOT/build/out"; B="$ROOT/build"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${KAMAILIO_VERSION:?}-${PKG_REVISION:?}"
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
mkdir -p "$STAGE/usr/sbin" "$STAGE/usr/lib/kamailio" "$STAGE/etc/kamailio"
cp -a /usr/sbin/kamailio "$STAGE/usr/sbin/" 2>/dev/null || true
cp -a /usr/lib/kamailio/. "$STAGE/usr/lib/kamailio/" 2>/dev/null || true
cp -a /etc/kamailio/. "$STAGE/etc/kamailio/" 2>/dev/null || true
write_deb_control "$STAGE" kamailio "$VER" "$ARCH" \
  "Kamailio ${KAMAILIO_VERSION} SIP proxy (db_mysql db_postgres tls kazoo rabbitmq)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
