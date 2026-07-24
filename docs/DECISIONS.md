# Decisions

Durable record of deliberate scope/technical decisions for this builder.

## D-01: No video support (2026-07-23)

**Decision:** The Kazoo 4.4 stack built here does **not** support video at this
time. FreeSWITCH is compiled with `--disable-libvpx --disable-libyuv`, so the
package ships **no VP8/VP9 video codecs**.

**Status:** Accepted.

**Context / rationale:**
- We do not intend to support video at this time — it is out of product scope.
- The only FreeSWITCH module we build is `mod_kazoo` (Kazoo's event-socket
  integration), which is SIP/media signalling only and needs no video codecs.
- Independently, FreeSWITCH's bundled libvpx fails to build on arm64 (it does
  not generate `vpx_config.h` for aarch64 in our build environment), so keeping
  video would also block the arm64 leg.

**Consequences:**
- Audio telephony is fully functional: calls, media proxy, IVR, voicemail, fax,
  conferencing audio.
- Video calling / video conferencing via FreeSWITCH is unavailable.
- The build succeeds identically on amd64 and arm64.

**If this is ever revisited:** re-enabling video means dropping
`--disable-libvpx --disable-libyuv` in `scripts/build-freeswitch.sh` **and**
fixing the arm64 bundled-libvpx build (or switching to system libvpx). Treat it
as a deliberate feature with its own validation.
