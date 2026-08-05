#!/usr/bin/env bash
# build-freeswitch.sh — build FreeSWITCH 1.10.9 + mod_kazoo into a `freeswitch` .deb.
# Ports kazoo-deploy build-packages.yml L378-612.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# modules.conf is the source of truth for what `make` builds (FS ignores the
# configure --with-modules flag in this tree — verified: the full default set,
# incl. mod_sofia, builds regardless). So we EDIT modules.conf: disable the
# incompatible modules and enable the ones we require. mod_opus is on by default
# but is listed here so the required set is explicit and self-documenting.
FS_ENABLE_MODULES=(
  event_handlers/mod_kazoo      # Kazoo ecallmgr integration (required)
  codecs/mod_opus               # OPUS codec
  applications/mod_http_cache   # HTTP media cache (http_cache:// URLs)
  formats/mod_shout             # MP3 playback/streaming (libmpg123/libshout)
  # Per-language say engines for dynamic number/date/currency/spelled playback.
  # mod_say_en is on by FS default (not listed). These are pure-FS modules (no
  # extra system deps); the matching lang phrase-macro XML configs + sound files
  # are installed at deploy time (kazoo-deploy). Italian (it) has no upstream
  # mod_say_it in FS 1.10.9, so it is intentionally absent. See issue #10.
  say/mod_say_es                # Spanish
  say/mod_say_fr                # French
  say/mod_say_de                # German
  say/mod_say_pt                # Portuguese
)

# Disable SignalWire/FFmpeg4-incompatible modules, then enable each required
# module (uncommenting it, or appending if absent).
# Portable across GNU/BSD sed: no `sed -i`; write to .new then mv.
configure_modules() {
  local f="$1" out="$1.new" m
  sed -E 's,^(endpoints/mod_verto|applications/mod_signalwire|applications/mod_av|applications/mod_spandsp)$,#\1,' "$f" > "$out"
  mv "$out" "$f"
  for m in "${FS_ENABLE_MODULES[@]}"; do
    if grep -qE "^#?${m}$" "$f"; then
      sed -E "s,^#?${m}$,${m}," "$f" > "$out"
      mv "$out" "$f"
    else
      echo "$m" >> "$f"
    fi
  done
}

# FS 1.10.9's bundled mod_kazoo decodes the $gen_call reply tag with
# ei_decode_ref, which fails on OTP 24+ where gen:do_call sends [alias|Mref].
# The openkazoo overlay uses ei_skip_term (opaque bytes) in 3 places.
assert_mod_kazoo_fix() {
  local n; n="$(grep -c ei_skip_term "$1" || true)"
  [ "${n:-0}" -ge 3 ] || die "mod_kazoo alias-tag fix missing (ei_skip_term=$n, need >=3)"
}

[ "${1:-}" = "--lib-only" ] && return 0

ROOT="$(repo_root)"; B="$ROOT/build"
CODENAME="$(codename_for "${DISTRO:?}")"
OUT="$ROOT/build/out/$CODENAME"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${FREESWITCH_VERSION:?}-${PKG_REVISION:?}~${CODENAME}"
DEB="$OUT/freeswitch_${VER}_${ARCH}.deb"
mkdir -p "$OUT"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

# --- sofia-sip 1.13.17 from source (Debian's is too old for FS >=1.13.12) ---
if ! pkg-config --modversion sofia-sip-ua 2>/dev/null | grep -qE '^1\.1[3-9]'; then
  apt-get remove -y --purge libsofia-sip-ua-dev libsofia-sip-ua0 2>/dev/null || true
  rm -rf "$B/sofia-sip"
  git clone --depth 1 --branch "v${SOFIA_SIP_VERSION:?}" \
    https://github.com/freeswitch/sofia-sip.git "$B/sofia-sip"
  ( cd "$B/sofia-sip" && ./autogen.sh && ./configure --prefix=/usr && make -j"$(nproc)" && make install )
  ldconfig
fi

# --- spandsp 3.x from source (Debian ships 0.0.6) ---
if ! grep -q 'SPANDSP_RELEASE_DATE_STRING' /usr/include/spandsp.h 2>/dev/null; then
  apt-get remove -y --purge libspandsp-dev libspandsp2 2>/dev/null || true
  rm -rf "$B/spandsp"
  git clone https://github.com/freeswitch/spandsp.git "$B/spandsp"
  git -C "$B/spandsp" checkout "${SPANDSP_REF:?}"
  # spandsp installs to the multiarch libdir (/usr/lib/<triplet>) regardless of
  # --libdir; the deb bundle step below searches there explicitly.
  ( cd "$B/spandsp" && ./autogen.sh && ./configure --prefix=/usr && make -j"$(nproc)" && make install )
  ldconfig
fi

# --- FreeSWITCH source + mod_kazoo overlay ---
rm -rf "$B/freeswitch" "$B/mod_kazoo-openkazoo"
git clone --depth 1 --branch "v${FREESWITCH_VERSION}" \
  https://github.com/signalwire/freeswitch.git "$B/freeswitch"
[ -d "$B/freeswitch/src/mod/event_handlers/mod_kazoo" ] || die "mod_kazoo missing from FS tree"
git clone --depth 1 --branch "${MOD_KAZOO_REF:?}" \
  https://github.com/openkazoo/freeswitch-mod_kazoo.git "$B/mod_kazoo-openkazoo"
cp -a "$B"/mod_kazoo-openkazoo/*.c "$B"/mod_kazoo-openkazoo/*.h \
      "$B"/mod_kazoo-openkazoo/*.S "$B"/mod_kazoo-openkazoo/kazoo.conf.xml \
      "$B/freeswitch/src/mod/event_handlers/mod_kazoo/"
assert_mod_kazoo_fix "$B/freeswitch/src/mod/event_handlers/mod_kazoo/kazoo_node.c"

( cd "$B/freeswitch" && ./bootstrap.sh -j )
configure_modules "$B/freeswitch/modules.conf"

# -D_GNU_SOURCE is REQUIRED: without it strdup is implicitly int-declared under
# -std=c99 and truncates 64-bit pointers to 32 bits -> SEGV on module load.
#
# --disable-libvpx --disable-libyuv: no video support, by design (see
# docs/DECISIONS.md D-01). We do not intend to support video at this time, and
# mod_kazoo (SIP/media event socket) needs no video codecs. This also sidesteps
# FS's bundled libvpx failing to generate vpx_config.h on arm64, so the build
# succeeds identically on amd64 + arm64. Re-enabling video is a deliberate
# future feature (and would require an arm64 libvpx fix).
# Module selection is driven entirely by modules.conf (edited by
# configure_modules above); FS ignores configure --with-modules in this tree.
export PATH="/usr/local/lib/erlang/bin:$PATH"
( cd "$B/freeswitch" \
  && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc \
       --with-openssl --enable-core-odbc-support \
       --disable-libvpx --disable-libyuv \
  && make -j"$(nproc)" CFLAGS="-Wno-error -D_GNU_SOURCE" \
  && make install )
# Gate: every requested module must have produced a .so (mod_kazoo missing =
# silent ecallmgr failure; the media modules are the point of this build).
for _m in mod_kazoo mod_opus mod_http_cache mod_shout \
          mod_say_es mod_say_fr mod_say_de mod_say_pt; do
  [ -f "/usr/lib/freeswitch/mod/${_m}.so" ] \
    || die "${_m}.so not built — check FreeSWITCH module deps/config"
done

echo ">> Packaging freeswitch deb: $DEB"
STAGE="$B/freeswitch-deb"; rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/etc/freeswitch" "$STAGE/var"
cp -a /usr/bin/freeswitch "$STAGE/usr/bin/"
# libfreeswitch.so* must live in /usr/lib (the binary's RUNPATH).
find /usr/lib -maxdepth 1 -name 'libfreeswitch.so*' -exec cp -a {} "$STAGE/usr/lib/" \;
# Bundle the from-source sofia-sip + spandsp shared libs too: FreeSWITCH links
# against them, but Debian's packaged versions are too old (that is *why* we
# built them from source), so apt cannot satisfy them on the target. Ship them
# in the package or freeswitch fails to load at runtime on a clean host.
# NOTE: search BOTH /usr/lib and the multiarch /usr/lib/<triplet> — spandsp's
# autotools ignore ./configure --libdir and always install to the multiarch
# libdir, so a bare `/usr/lib -maxdepth 1` glob silently drops libspandsp.so.3
# (FreeSWITCH then dies at boot: "libspandsp.so.3: cannot open shared object").
_MULTIARCH="$(gcc -dumpmachine 2>/dev/null || true)"
for _libdir in /usr/lib ${_MULTIARCH:+/usr/lib/$_MULTIARCH}; do
  [ -d "$_libdir" ] || continue
  find "$_libdir" -maxdepth 1 \( -name 'libsofia-sip-ua.so*' -o -name 'libspandsp.so*' \) \
    -exec cp -a {} "$STAGE/usr/lib/" \;
done
# Gate: libspandsp.so.3 MUST be bundled (FreeSWITCH links it) — fail loudly.
ls "$STAGE"/usr/lib/libspandsp.so.3* >/dev/null 2>&1 \
  || die "libspandsp.so.3 not bundled — check spandsp install libdir + bundle glob"
[ -d /usr/lib/freeswitch ] && cp -a /usr/lib/freeswitch "$STAGE/usr/lib/"
cp -a /etc/freeswitch/. "$STAGE/etc/freeswitch/" 2>/dev/null || true
printf '#!/bin/sh\nldconfig\n' > "$STAGE/DEBIAN/postinst"
printf '#!/bin/sh\nldconfig\n' > "$STAGE/DEBIAN/postrm"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
write_deb_control "$STAGE" freeswitch "$VER" "$ARCH" \
  "FreeSWITCH ${FREESWITCH_VERSION} with mod_kazoo (OTP 24+ alias-tag fix), OPUS, MP3 (mod_shout), HTTP cache, and say engines (en/es/fr/de/pt)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
