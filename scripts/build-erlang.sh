#!/usr/bin/env bash
# build-erlang.sh — build Erlang/OTP via kerl and wrap it into an `erlang` .deb.
# Ports kazoo-deploy build-packages.yml L128-245.
#
# OTP 26 is the floor AND ceiling for Kazoo 4.4: 4.4 declares
# {minimum_otp_vsn,"26"}, and OTP 27 hit a mod_kazoo <-> ecallmgr app-protocol
# wall (see spec §2.1). Do not bump past 26 while FreeSWITCH is in scope.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"
OUT="$ROOT/build/out"
STAGE="$ROOT/build/erlang-deb"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${OTP_VERSION:?}-${PKG_REVISION:?}"
DEB="$OUT/erlang_${VER}_${ARCH}.deb"

mkdir -p "$OUT"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

echo ">> Building OTP ${OTP_VERSION} via kerl (~30 min)"
export KERL_BUILD_BACKEND=git
export KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-debugger \
  --without-observer --without-et --without-megaco"
if [ ! -e "/root/.kerl/builds/otp-${OTP_VERSION}/otp_build_${OTP_VERSION}.release" ]; then
  kerl build "${OTP_VERSION}" "otp-${OTP_VERSION}"
fi
rm -rf /usr/local/lib/erlang
kerl install "otp-${OTP_VERSION}" /usr/local/lib/erlang

echo ">> Verifying OTP major version is 26"
/usr/local/lib/erlang/bin/erl \
  -eval 'io:format("~s~n",[erlang:system_info(otp_release)]),halt().' -noshell \
  | grep -q '^26' || die "installed OTP is not major 26"

echo ">> Packaging erlang deb: $DEB"
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/local/lib/erlang" "$STAGE/usr/local/bin"
cp -a /usr/local/lib/erlang/. "$STAGE/usr/local/lib/erlang/"
ln -sf /usr/local/lib/erlang/bin/erl  "$STAGE/usr/local/bin/erl"
ln -sf /usr/local/lib/erlang/bin/erlc "$STAGE/usr/local/bin/erlc"
write_deb_control "$STAGE" erlang "$VER" "$ARCH" \
  "Erlang/OTP ${OTP_VERSION} built via kerl for Kazoo 4.4 (system OpenSSL 3.x, no wx/javac)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"
ls -la "$DEB"
