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

## D-02: Debian 11 builds pin a frozen bullseye-security snapshot (2026-09-10)

**Decision:** The Debian 11 build image sources `bullseye-security` from
`snapshot.debian.org` at a pinned timestamp (`SECURITY_SNAPSHOT`, currently
`20260824T000000Z`) and disables apt's `Valid-Until` check. Plain `bullseye`
and `bullseye-updates` still come from `deb.debian.org`.

**Status:** Accepted.

**Context / rationale:**
- Bullseye left LTS in August 2026. Two failures landed together on
  `deb.debian.org`: the `bullseye-security` `InRelease` file went past its
  `Valid-Until`, so `apt-get update` exits 100, and the matching pool stopped
  serving `.deb` files, so every fetch 404s. All eight Debian 11 CI legs died
  at image build.
- `archive.debian.org` carries `bullseye` but, as of 2026-09, has no
  `bullseye-security` Release file, so it cannot replace the security suite.
- Only the security line is repointed. `snapshot.debian.org` drops connections
  on large downloads, so leaving `build-essential` and friends on the fast
  mirror keeps the image build reliable. `Acquire::Retries "10"` covers the
  smaller security fetches.
- The pin reproduces what `bullseye-security` last shipped, so `libssl-dev`
  stays at `1.1.1w-0+deb11u8`, the version this image has always built OTP
  26.2.5.20 against.

**Consequences:**
- Debian 11 packages are built against a frozen toolchain. Bullseye receives no
  further security updates, so there is nothing newer to miss, but the build
  environment will not improve either.
- `Valid-Until` enforcement is off for this image. Signature verification is
  untouched, so packages are still checked against Debian's keyring.
- Debian 12 is unaffected and keeps normal mirrors.

**If this is ever revisited:** once `archive.debian.org` publishes
`bullseye-security`, repoint there and drop the snapshot pin. When Debian 11
support is dropped, delete `docker/Dockerfile.debian-11` and the `debian-11`
matrix entries instead of maintaining the pin.
