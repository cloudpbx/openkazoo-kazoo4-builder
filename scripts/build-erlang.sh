#!/usr/bin/env bash
# build-erlang.sh — package the image's Erlang/OTP tree into an `erlang` .deb.
# Ports kazoo-deploy build-packages.yml L128-245, but the kerl OTP build now
# lives in docker/Dockerfile.<distro> (cached layer) so that kazoo/freeswitch —
# which run in their own fresh containers — find Erlang on PATH. This script
# just verifies and packages /usr/local/lib/erlang.
#
# OTP 26 is the floor AND ceiling for Kazoo 4.4: 4.4 declares
# {minimum_otp_vsn,"26"}, and OTP 27 hit a mod_kazoo <-> ecallmgr app-protocol
# wall (see spec §2.1). Do not bump past 26 while FreeSWITCH is in scope.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"
CODENAME="$(codename_for "${DISTRO:?}")"
OUT="$ROOT/build/out/$CODENAME"
STAGE="$ROOT/build/erlang-deb"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${OTP_VERSION:?}-${PKG_REVISION:?}~${CODENAME}"
DEB="$OUT/erlang_${VER}_${ARCH}.deb"

mkdir -p "$OUT"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

echo ">> Verifying image-built OTP is present and major version 26"
[ -x /usr/local/lib/erlang/bin/erl ] || die "/usr/local/lib/erlang not found — is this the build image?"
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
  "Erlang/OTP ${OTP_VERSION} built via kerl for Kazoo 4.4 (system OpenSSL, no wx/javac)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"
ls -la "$DEB"
