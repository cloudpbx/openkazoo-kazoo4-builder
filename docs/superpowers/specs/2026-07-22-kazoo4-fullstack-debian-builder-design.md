# openkazoo-kazoo4-builder — Design Spec

**Date:** 2026-07-22
**Status:** Approved (design phase)
**Author:** drafted with Claude Code via superpowers:brainstorming

---

## 1. Purpose

A CI-driven build service that produces **signed Debian 12 `.deb` packages** for a
complete **Kazoo 4.4 telephony stack**, for **amd64 and arm64**, and publishes them
to a **GitHub Pages apt repository**.

It combines two existing sources of truth:

- **Structure / publish philosophy** — cloned from
  [`cloudpbx/openkazoo-kazoo5-builder`](https://github.com/cloudpbx/openkazoo-kazoo5-builder):
  `Makefile` entrypoints, `config/` version pins, `scripts/` build+sign+publish+verify,
  `tests/` bats, `.github/workflows/` CI, gh-pages apt repo, GPG signing, docs.
- **Build recipe / hard-won knowledge** — ported from the authoritative
  `kazoo-deploy` Ansible playbook
  `kazoo-deploy/ansible/playbooks/build-packages.yml`
  (branch `grahamsnz/otp-22-downgrade`). Every explanatory comment in that playbook
  encodes a real failure mode and is carried over verbatim — the fixes ARE the value.

This is **not** a single-package build like kazoo5-builder. It is a 4-component stack.

---

## 2. Components

Four independently-versioned `.deb` packages, each pinned via `config/`:

| Package | Version | Source | Key notes |
|---|---|---|---|
| `erlang` | `26.2.5.20` (built via kerl) | `erlang/otp` | Shipped as its **own deb**. OTP 26 is the **floor and the ceiling** for this stack. |
| `kazoo` | `4.4` | `cloudpbx/openkazoo@4.4` (identical tree to `openkazoo/kazoo@4.4`) | `rebar3 compile && rebar3 tar` on the **default** profile; `rebar.config` patched to **`include_erts=false`** so the deb depends on the `erlang` deb instead of bundling ERTS. |
| `freeswitch` | `1.10.9` (pinned tag) | `signalwire/freeswitch` | 1.10.12+ dropped `mod_kazoo`. Needs sofia-sip 1.13.17 + spandsp 3.x from source; `mod_kazoo` overlaid from `openkazoo/freeswitch-mod_kazoo@4.4`; built with `-Wno-error -D_GNU_SOURCE`; incompatible modules disabled. |
| `kamailio` | `5.8.8` | `kamailio/kamailio` | Built with modules `db_mysql db_postgres tls kazoo rabbitmq`. |

### 2.1 Critical hard-won knowledge (imported as-is)

1. **OTP 27 is a documented dead-end** for this stack. The playbook (L139-142) records that
   OTP 27 "hit a mod_kazoo ↔ ecallmgr app-protocol wall". Kazoo 4.4 declares
   `{minimum_otp_vsn,"26"}`. Therefore **OTP 26.2.5.20 is the target and there is no
   OTP-27 phase while FreeSWITCH/mod_kazoo remain in scope.** (If FreeSWITCH were ever
   dropped, OTP 27 for Kazoo-the-Erlang-app alone could be revisited — recorded for the
   future, not planned now.)
2. **mod_kazoo alias-tag fix** (playbook L465-497): FreeSWITCH 1.10.9's bundled `mod_kazoo`
   decodes the `$gen_call`/`net_kernel` reply tag with `ei_decode_ref`, which fails on
   OTP 24+ where `gen:do_call` sends an `[alias|Mref]` improper list. The fix overlays
   `openkazoo/freeswitch-mod_kazoo@4.4` (uses `ei_skip_term`), verified by asserting
   `ei_skip_term` appears **≥3 times** in `kazoo_node.c`.
3. **`-D_GNU_SOURCE` on the FreeSWITCH build** (playbook L527-536): without it, `strdup`
   is implicitly declared int-returning under `-std=c99`, truncating 64-bit heap pointers
   to 32 bits → SEGV on module load. `-Wno-error` is also required.
4. **`rebar3 compile && rebar3 tar` on the default profile** sidesteps the openkazoo
   `Makefile`'s `git describe --tags --match 'v*'` release gate entirely — no
   auto-tagging or upstream-Makefile patching needed. Output tarball lands in
   `_build/default/rel/kazoo/*.tar.gz`.
5. **`include_erts=false`** patch to `rebar.config` (playbook L268-281): idempotent —
   replaces `{include_erts, true}` if present, else inserts `{include_erts, false}` into
   the `relx` block.
6. **FreeSWITCH module disables** (playbook L507-518): comment out
   `mod_verto`, `mod_signalwire`, `mod_av`, `mod_spandsp` in `modules.conf`
   (SignalWire libks + FFmpeg4 API breakage); ensure `event_handlers/mod_kazoo` is
   enabled.
7. **sofia-sip / spandsp from source** (playbook L392-449): purge Debian's older
   packages first; build sofia-sip `v1.13.17` and spandsp 3.x from the freeswitch org
   repos with idempotent "already installed" guards.

---

## 3. Builder architecture

### 3.1 Build image
- Single `docker/Dockerfile.debian-12` (bookworm), built **natively per-arch**
  (no cross-compilation / QEMU for the compile steps).
- Installs the full apt toolchain from the playbook's `bootstrap` task
  (build-essential, autoconf, flex/bison, all FreeSWITCH + Kamailio `-dev` deps,
  dpkg-dev/debhelper/debsigs, gnupg, golang for secsipidx, etc.), plus `kerl` and
  `rebar3`. No AWS CLI (we publish to gh-pages, not S3).

### 3.2 Per-component build scripts
- `scripts/build-erlang.sh` — kerl build of OTP 26.2.5.20
  (`KERL_BUILD_BACKEND=git`, configure opts `--without-javac --without-wx
  --without-debugger --without-observer --without-et --without-megaco`),
  install to a staging tree, wrap into `erlang_<ver>-<rev>_<arch>.deb` via `dpkg-deb`.
- `scripts/build-kazoo.sh` — clone `cloudpbx/openkazoo@4.4`, patch `include_erts=false`,
  `rebar3 compile` (hard gate), `rebar3 tar`, stage tarball into `/opt/kazoo`, wrap deb
  (depends on `erlang`).
- `scripts/build-freeswitch.sh` — sofia-sip + spandsp from source, clone FS 1.10.9,
  overlay + verify mod_kazoo fix, `bootstrap.sh`, edit `modules.conf`, `configure`,
  `make -D_GNU_SOURCE`, `make install`, gate on `mod_kazoo.so`, wrap deb bundling
  `libfreeswitch.so*`, modules, and `/etc/freeswitch`.
- `scripts/build-kamailio.sh` — clone 5.8.8, `make cfg` + build with the module set,
  wrap deb.
- Packaging uses **`dpkg-deb --build` with hand-written `DEBIAN/control`** (as the
  playbook does), **not** FPM. Arch normalization: `x86_64→amd64`, `aarch64→arm64`.
- Each script carries the playbook's **skip-if-already-built** guard so re-runs are cheap.

### 3.3 Sign
- `scripts/sign.sh` — import `GPG_PRIVATE_KEY` (+ `GPG_PASSPHRASE`) from env/CI secrets
  (loopback pinentry), `debsigs --sign=origin` every staged `.deb`, export `pubkey.asc`,
  scrub the key from the keyring afterward. Falls back to `tests/fixtures/gpg/` for local
  dry runs.

### 3.4 Publish (gh-pages apt repo)
- `scripts/publish.sh` — assemble a **proper pooled apt repository** (adapting the
  playbook's `apt-ftparchive` step from S3 to gh-pages):
  - `pool/main/<pkg>/…deb`
  - `dists/bookworm/main/binary-amd64/Packages[.gz]`
  - `dists/bookworm/main/binary-arm64/Packages[.gz]`
  - signed `Release` + `InRelease` (inline) + `Release.gpg` (detached)
  - `pubkey.asc` at the site root
- Published to the `gh-pages` branch → served at
  `https://cloudpbx.github.io/openkazoo-kazoo4-builder/`.

### 3.5 Makefile
Top-level entrypoints only; logic lives in `scripts/`:
`build COMPONENT=<erlang|kazoo|freeswitch|kamailio> ARCH=<amd64|arm64>`,
`sign`, `publish`, `verify`, `test`, `clean`, `help`.

### 3.6 CI
- `.github/workflows/build.yml` — matrix `{component} × {amd64, arm64}` on
  native runners (`ubuntu-24.04` + `ubuntu-24.04-arm`). On a version tag:
  build → sign → publish to gh-pages → GitHub Release with all debs attached.
  Supports a `publish=false` dry-run input (mirrors kazoo5-builder's dry-run journey).
- `.github/workflows/verify-install.yml` — installs from the published repo in clean
  bookworm amd64 + arm64 containers and smoke-tests presence
  (`kazoo`, `freeswitch` + `mod_kazoo.so`, `kamailio`, `erlang`).

### 3.7 Tests
- `tests/` bats: version-string synthesis, `DEBIAN/control` correctness, arch
  normalization, `include_erts` patch idempotency, mod_kazoo `ei_skip_term ≥3` gate,
  `libfreeswitch.so` presence gate, `modules.conf` enable/disable assertions.

---

## 4. Config pins (`config/`)

Single source of truth, all one-line bumpable:

```
kazoo.version        4.4
otp.version          26.2.5.20
rebar.version        latest        # playbook fetches s3.amazonaws.com/rebar3 (unpinned); we pin a known-good tag here
freeswitch.version   1.10.9
sofia-sip.version    1.13.17
spandsp.ref          master        # playbook clones freeswitch/spandsp default branch (unpinned); we should pin a commit for reproducibility
mod_kazoo.ref        4.4
kamailio.version     5.8.8
package.revision     1
```

> Note: the playbook leaves `rebar3` and `spandsp` unpinned. This builder will pin
> both to specific tags/commits in `config/` for reproducibility, resolving the exact
> values during implementation (a small improvement over the playbook, per the
> reproducibility risk below).

---

## 5. End-user install surface

```bash
curl -fsSL https://cloudpbx.github.io/openkazoo-kazoo4-builder/pubkey.asc \
  | sudo tee /usr/share/keyrings/openkazoo.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/openkazoo.asc] \
https://cloudpbx.github.io/openkazoo-kazoo4-builder bookworm main" \
  | sudo tee /etc/apt/sources.list.d/openkazoo.list
sudo apt-get update
sudo apt-get install -y kazoo freeswitch kamailio    # erlang pulled in as a dependency
```

Documented in `docs/INSTALL.md`.

---

## 6. Versioning

- `config/kazoo.version = 4.4` is a **branch**, so `build-kazoo.sh` synthesizes a
  pseudo-version `4.4.0~4.4.<YYYYMMDD>.<shortsha>`. Other components use their upstream
  version verbatim + `package.revision`.
- Release tags: `v4.4.0-<YYYYMMDD>-1` trigger the build+publish+release workflow.

---

## 7. Assumptions

1. **Native arm64 GitHub runners** (`ubuntu-24.04-arm`), not QEMU emulation
   (FreeSWITCH alone is ~60 min; emulated arm64 would be many hours).
2. **Build platform is Debian 12** for all components; no EL/RPM path in v1.
3. **OTP-27 is documented-blocked**, not attempted, while FreeSWITCH/mod_kazoo are in scope.
4. FreeSWITCH and Kamailio are built for **both** arches.

---

## 8. Known risks

| Risk | Mitigation |
|---|---|
| **Repo is private** — assumption (1) presumed public (free arm64 runners); private repos have runner/Pages billing implications. | Confirm plan covers `ubuntu-24.04-arm` + Pages; or flip repo public before CI runs. |
| **CI wall-clock** — full matrix is long (OTP ~30m, FS ~60m, ×2 arch). | Per-component layer caching, matrix parallelism, skip-if-built guards. |
| **arm64 FreeSWITCH / sofia-sip / spandsp** — playbook is amd64-proven only. | Shake out in `publish=false` dry-runs; treat arm64 FS as the highest-risk leg. |
| **GPG signing key** — cannot be set by the agent. | Generate keypair + document; maintainer sets `GPG_PRIVATE_KEY`/`GPG_PASSPHRASE` secrets. |
| **Upstream ref reachability** — FS/sofia/spandsp/mod_kazoo refs must stay live. | Pin exact tags/refs in `config/`; fail loudly with clear messages. |
| **First green requires real CI iteration** (kazoo5-builder took 11 dry-runs). | Explicit dry-run mode; document the iteration journey in STATUS.md. |

---

## 9. Out of scope (v1)

- RPM / EL9 packages.
- S3 publishing (playbook's model; we use gh-pages).
- OTP 27.
- Cross-compilation (each arch builds natively).
