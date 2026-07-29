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
  && make FLAVOUR=kamailio include_modules="db_mysql db_postgres tls kazoo rabbitmq presence presence_xml presence_dialoginfo presence_mwi websocket outbound uuid" PREFIX=/usr cfg \
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

# Gate: the presence/websocket/outbound module groups kazoo-configs-kamailio
# loadmodule's must be present (they need include_modules + libxml2/libunistring).
for m in websocket presence presence_xml outbound uuid; do
  find "$STAGE" -path "*kamailio/modules/$m.so" -print -quit | grep -q . \
    || die "kamailio module '$m' missing — check include_modules and build deps (libxml2-dev/libunistring-dev/uuid-dev)"
done

# systemd unit + service user. dpkg-deb builds from a staging tree with no
# maintainer scripts, so — unlike Debian's kamailio package — nothing creates
# the kamailio user/group or installs a unit. Ship both. The unit runs as the
# kamailio user with CAP_NET_BIND_SERVICE so it can bind privileged SIP ports
# (5060/5061) without root; deployers may drop in an override for ExecStart.
mkdir -p "$STAGE/lib/systemd/system"
cat > "$STAGE/lib/systemd/system/kamailio.service" <<'UNIT'
[Unit]
Description=Kamailio - the Open Source SIP Server
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=kamailio
Group=kamailio
Environment='CFGFILE=/etc/kamailio/kamailio.cfg'
Environment='SHM_MEMORY=64'
Environment='PKG_MEMORY=8'
EnvironmentFile=-/etc/default/kamailio
PIDFile=/run/kamailio/kamailio.pid
ExecStart=/usr/sbin/kamailio -P /run/kamailio/kamailio.pid -f $CFGFILE -m $SHM_MEMORY -M $PKG_MEMORY --atexit=no
Restart=on-failure
RuntimeDirectory=kamailio
RuntimeDirectoryMode=0770
AmbientCapabilities=CAP_CHOWN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if ! getent group kamailio >/dev/null; then
  addgroup --system kamailio
fi
if ! getent passwd kamailio >/dev/null; then
  adduser --system --no-create-home --home /run/kamailio \
    --ingroup kamailio --shell /usr/sbin/nologin kamailio
fi
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload || true
fi
POSTINST
chmod 0755 "$STAGE/DEBIAN/postinst"

write_deb_control "$STAGE" kamailio "$VER" "$ARCH" \
  "Kamailio ${KAMAILIO_VERSION} SIP proxy (db_mysql db_postgres tls kazoo rabbitmq presence websocket outbound)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
