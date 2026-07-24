# Architecture

This builder produces signed Debian 12 `.deb` packages for the Kazoo 4.4
telephony stack and publishes them to a GitHub Pages apt repository. The build
recipe is a faithful port of the `kazoo-deploy` `build-packages.yml` Ansible
playbook; the repository layout follows `openkazoo-kazoo5-builder`.

## Components

| Package | Version | Upstream | Notes |
|---|---|---|---|
| `erlang` | 26.2.5.20 | `erlang/otp` (via kerl) | OTP 26 is the floor **and** ceiling — see below |
| `kazoo` | 4.4 | `cloudpbx/openkazoo@4.4` | `rebar3 compile && rebar3 tar` (default profile), `include_erts=false` |
| `freeswitch` | 1.10.9 | `signalwire/freeswitch` | + sofia-sip 1.13.17 & spandsp (source); `mod_kazoo` overlaid from `openkazoo/freeswitch-mod_kazoo@4.4`; **no video** (`--disable-libvpx/--disable-libyuv`, see DECISIONS.md D-01) |
| `kamailio` | 5.8.8 | `kamailio/kamailio` | modules `db_mysql db_postgres tls kazoo rabbitmq` |

### The OTP-26 ceiling

Kazoo 4.4 declares `{minimum_otp_vsn,"26"}`. OTP 27 was tried and hit a
`mod_kazoo` ↔ `ecallmgr` app-protocol wall. **Do not bump `config/otp.version`
past 26 while FreeSWITCH/mod_kazoo are in scope.**

### The mod_kazoo overlay

FreeSWITCH 1.10.9's bundled `mod_kazoo` decodes the `$gen_call` reply tag with
`ei_decode_ref`, which fails on OTP 24+ (`gen:do_call` sends `[alias|Mref]`).
The build overlays `openkazoo/freeswitch-mod_kazoo@4.4` (uses `ei_skip_term`)
and asserts the fix is present (`ei_skip_term` appears ≥3× in `kazoo_node.c`).
FreeSWITCH is compiled with `-Wno-error -D_GNU_SOURCE` (the latter prevents a
`strdup` pointer-truncation SEGV under `-std=c99`).

## Build flow

```
config/*.version ─┐
                  ├─► docker/Dockerfile.debian-{11,12} (kerl, rebar3, toolchain)
                  │        │
                  │        ▼   (make build COMPONENT=… runs inside the image)
                  └─► scripts/build-<component>.sh ─► build/out/<pkg>_<ver>_<arch>.deb
                                                          │
                            scripts/sign.sh (debsigs) ◄───┘
                                     │
                            scripts/publish.sh (reprepro) ─► build/repo/{pool,dists}/  + pubkey.asc
```

- **Build image:** one image per Debian release (`debian-11` bullseye,
  `debian-12` bookworm), selected via `make ... DISTRO=`, built natively per-arch
  (no cross-compilation). Toolchain mirrors the playbook's bootstrap task.
  Note: Debian 11 ships OpenSSL 1.1.1 (Debian 12 has 3.x).
- **Packaging:** `dpkg-deb --build` with a hand-written `DEBIAN/control`
  (via `write_deb_control` in `scripts/lib.sh`), mirroring the playbook. Each
  package version carries a `~<codename>` suffix (e.g. `-1~bullseye`), and debs
  are staged under `build/out/<codename>/`.
- **Signing:** `debsigs --sign=origin`, key from `GPG_PRIVATE_KEY`.
- **Publishing:** `reprepro` pooled apt repo with two distributions
  (`bullseye` + `bookworm`), each `Architectures: amd64 arm64`; debs are routed
  by codename. Deployed to the `gh-pages` branch.

## CI

- `.github/workflows/build.yml` — matrix `{erlang,kazoo,freeswitch,kamailio} ×
  {amd64,arm64} × {debian-11,debian-12}` (16 legs) on native runners
  (`ubuntu-24.04`, `ubuntu-24.04-arm`). On a `v4.*` tag: build → sign → publish
  to gh-pages → GitHub Release. A `workflow_dispatch` `publish=false` input runs
  a build-only dry-run.
- `.github/workflows/verify-install.yml` — installs from the published apt repo
  in clean `debian:11`/`debian:12` containers (both arches, matching codename)
  and smoke-tests the artifacts.

## Tests

`tests/unit/*.bats` (bats-core, vendored at `tests/bats/`) cover the pure-logic
units: arch normalization, deb control generation, the `include_erts` patch,
`modules.conf` edits, the `mod_kazoo` fix gate, version synthesis, and the
sign/publish guards. Full compilation builds are validated in CI.

## Reference

Design spec: `docs/superpowers/specs/2026-07-22-kazoo4-fullstack-debian-builder-design.md`
Implementation plan: `docs/superpowers/plans/2026-07-22-kazoo4-fullstack-debian-builder.md`
