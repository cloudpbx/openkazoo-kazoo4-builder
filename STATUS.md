# Project Status

**Last updated:** 2026-07-22
**Status:** scaffolding complete; first CI dry-run pending.

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

## Open risks

- **Repo is private** → confirm arm64 runner + GitHub Pages billing, or make the
  repo public (kazoo5-builder is public).
- **arm64 FreeSWITCH / sofia-sip / spandsp** are unproven — the playbook is
  amd64-only. Expect the `freeswitch × arm64` leg to need the most iteration.
- **Debian 11 (bullseye) is unproven** — the playbook targets Debian 12. Bullseye
  ships OpenSSL 1.1.1 (not 3.x) and older `-dev` libs; OTP 26 builds against
  1.1.1, but the `freeswitch`/`kamailio` bullseye legs may need shake-out. The
  toolchain list is identical to bookworm's; any package/ABI diffs surface in CI.
- **First green will take several dry-runs** (kazoo5-builder took 11); the matrix
  is now 16 legs.
- The build image and full compilation are validated only in CI (local runs
  cover the bats logic units, not the multi-hour builds).
