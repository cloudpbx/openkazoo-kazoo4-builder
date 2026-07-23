# Project Status

**Last updated:** 2026-07-23
**Status:** all 4 components build green on both distros (validated locally, arm64). amd64 legs pending CI.

## Build validation (local, arm64)

Every component was built end-to-end in the real Docker images on an arm64 host.
All 8 debs produced and inspected:

| Component | bookworm | bullseye | Notes |
|---|---|---|---|
| `erlang` | ✅ | ✅ | OTP 26.2.5.20; bullseye against OpenSSL 1.1.1w |
| `kazoo` | ✅ | ✅ | rebar3 compile → release → deb, `Depends: erlang (>= 26)` |
| `kamailio` | ✅ | ✅ | 153 modules incl. kazoo/rabbitmq/tls |
| `freeswitch` | ✅ | ✅ | `mod_kazoo.so` + bundled sofia-sip/spandsp; video disabled (see below) |

Six bugs were found and fixed during this validation (all would have failed CI):
OTP-in-image (Erlang unavailable to kazoo/freeswitch), Go 1.15→1.22 pin
(bullseye martini/secsipid needs `io/fs`), `libtool-bin` (FS bootstrap),
`python3-distutils` (FS configure), kamailio `/usr/lib64` module path (+ gate),
and FreeSWITCH `--disable-libvpx/--disable-libyuv` (bundled libvpx unbuildable on
arm64; video not needed for `mod_kazoo`).

**amd64** builds were not run locally (arm64 host; emulation too slow) — they run
natively in CI.

## Scope

Full Kazoo 4.4 stack (`erlang`, `kazoo`, `freeswitch`, `kamailio`) as signed
`.deb`s for **Debian 11 (bullseye) + Debian 12 (bookworm)**, **amd64 + arm64**,
published to a GitHub Pages apt repo. Build recipe ported from the
`kazoo-deploy` `build-packages.yml` playbook; structure from
`openkazoo-kazoo5-builder`.

## What's implemented

- `config/` version pins, `Makefile` (with `DISTRO` selector), MIT `LICENSE`.
- Debian 11 + Debian 12 build images (`docker/Dockerfile.debian-11`, `docker/Dockerfile.debian-12`): kerl, rebar3, full toolchain.
- Four component build scripts (`scripts/build-{erlang,kazoo,freeswitch,kamailio}.sh`), distro-parameterized (`~<codename>` version suffix, `build/out/<codename>/`).
- `scripts/sign.sh` (debsigs) and `scripts/publish.sh` (reprepro, two suites: bullseye + bookworm, multi-arch).
- CI: `.github/workflows/build.yml` (matrix `component × arch × distro`, 16 legs) + `verify-install.yml` (arch × distro).
- 15 bats unit tests (pure-logic units), all green locally.
- Docs: README, INSTALL, ARCHITECTURE, CONTRIBUTING, GPG-KEY.

## Key constraints

- **OTP 26.2.5.20 is the target and the ceiling.** Kazoo 4.4 requires OTP 26+;
  OTP 27 hit a `mod_kazoo` ↔ `ecallmgr` app-protocol wall. Do not bump past 26
  while FreeSWITCH is in scope.
- FreeSWITCH pinned to 1.10.9 (1.10.12+ dropped `mod_kazoo`); `mod_kazoo`
  overlaid from `openkazoo/freeswitch-mod_kazoo@4.4` (OTP 24+ alias-tag fix),
  built with `-Wno-error -D_GNU_SOURCE`.
- `kazoo` deb is built `include_erts=false` and depends on the `erlang` deb.

## How to cut the first release

1. Maintainer sets `GPG_PRIVATE_KEY` (+ optional `GPG_PASSPHRASE`) — see
   `docs/GPG-KEY.md`.
2. Run the `build` workflow with `publish=false` (Actions → build → Run
   workflow) and iterate until all 16 matrix legs are green. Document each fix in
   its own commit.
3. Tag to publish:
   ```bash
   git tag "v4.4.0-$(date -u +%Y%m%d)-1"
   git push origin "v4.4.0-$(date -u +%Y%m%d)-1"
   ```

## Deliberate scope decisions

- **FreeSWITCH ships without VP8/VP9 video** (`--disable-libvpx --disable-libyuv`).
  `mod_kazoo` is SIP/media only, and bundled libvpx cannot build on arm64. Audio
  telephony is unaffected. Re-enable video later as a feature (needs an arm64
  libvpx fix) if conferencing video is required.

## Open risks

- **Repo is private** → confirm arm64 runner + GitHub Pages billing, or make the
  repo public (kazoo5-builder is public).
- **amd64 not yet built** — all local validation was arm64 (host arch). The amd64
  legs run natively in CI; the playbook already proved FreeSWITCH on amd64, so
  risk is low, but the amd64 matrix still needs a green CI run.
- **First green in CI** may still need iteration across the 16 legs; the six
  build bugs found locally are already fixed on this branch.
