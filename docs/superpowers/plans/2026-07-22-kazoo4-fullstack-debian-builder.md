# Kazoo 4.4 Full-Stack Debian Builder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CI-driven service that produces signed Debian 12 `.deb` packages (amd64 + arm64) for the Kazoo 4.4 telephony stack — `erlang`, `kazoo`, `freeswitch`, `kamailio` — and publishes them to a GitHub Pages apt repository.

**Architecture:** A single Debian-12 Docker build image carries the full toolchain (kerl, rebar3, FreeSWITCH/Kamailio dev deps). Four per-component build scripts port the proven recipe from the `kazoo-deploy` `build-packages.yml` Ansible playbook into shell, each producing a `.deb` via `dpkg-deb`. `sign.sh` (debsigs) and `publish.sh` (reprepro, multi-arch pooled apt repo) are adapted from `openkazoo-kazoo5-builder`. A GitHub Actions matrix (`component × arch`) on native runners builds → signs → publishes to `gh-pages` → attaches to a Release. `bats` covers pure-logic units; full builds are validated by CI dry-runs.

**Tech Stack:** Bash, GNU Make, Docker (Debian 12 / bookworm), kerl, rebar3, dpkg-deb, debsigs, reprepro, GnuPG, GitHub Actions, bats-core.

**Reference sources (read before implementing):**
- Design spec: `docs/superpowers/specs/2026-07-22-kazoo4-fullstack-debian-builder-design.md`
- Recipe of record: `~/Projects/kazoo-deploy/kazoo-deploy/ansible/playbooks/build-packages.yml` (branch `grahamsnz/otp-22-downgrade`) — every comment there encodes a real failure mode.
- Scaffolding of record: `cloudpbx/openkazoo-kazoo5-builder` (Makefile, scripts/sign.sh, scripts/publish.sh).

**Conventions used throughout:**
- Arch normalization: `x86_64→amd64`, `aarch64→arm64`.
- Package version = `<upstream>-<PKG_REVISION>` (e.g. `1.10.9-1`); Kazoo uses a synthesized pseudo-version (Task 6).
- All scripts: `set -euo pipefail`, a `die()` helper, and load `scripts/lib.sh`.
- Every build script is idempotent: it skips work if the target `.deb` already exists (ported from the playbook's `creates:`/`find` guards).

---

## File Structure

```
openkazoo-kazoo4-builder/
├── Makefile                         # entrypoints: build/sign/publish/verify/test
├── README.md  STATUS.md  LICENSE
├── .gitignore  .gitmodules
├── config/                          # version pins (single source of truth)
│   ├── kazoo.version  otp.version  rebar.version  package.revision
│   ├── freeswitch.version  sofia-sip.version  spandsp.ref  mod_kazoo.ref
│   └── kamailio.version
├── docker/
│   └── Dockerfile.debian-12         # full build toolchain, kerl, rebar3
├── scripts/
│   ├── lib.sh                       # shared: die, arch_normalize, load_config, deb_build helpers
│   ├── build-erlang.sh              # kerl OTP 26.2.5.20 → erlang deb
│   ├── build-kazoo.sh               # openkazoo@4.4, include_erts=false → kazoo deb
│   ├── build-freeswitch.sh          # FS 1.10.9 + sofia/spandsp + mod_kazoo overlay → freeswitch deb
│   ├── build-kamailio.sh            # kamailio 5.8.8 → kamailio deb
│   ├── sign.sh                      # debsigs sign all built debs
│   └── publish.sh                   # reprepro multi-arch pooled apt repo
├── tests/
│   ├── bats/                        # bats-core submodule
│   └── unit/                        # *.bats: lib, per-component logic
├── .github/workflows/
│   ├── build.yml                    # matrix component×arch → sign → publish → release
│   └── verify-install.yml           # apt-install smoke test in clean containers
└── docs/
    ├── INSTALL.md  ARCHITECTURE.md  CONTRIBUTING.md  GPG-KEY.md
    └── superpowers/{specs,plans}/
```

---

## Task 1: Repo scaffolding — config pins, Makefile, metadata

**Files:**
- Create: `config/kazoo.version`, `config/otp.version`, `config/rebar.version`, `config/package.revision`, `config/freeswitch.version`, `config/sofia-sip.version`, `config/spandsp.ref`, `config/mod_kazoo.ref`, `config/kamailio.version`
- Create: `Makefile`, `LICENSE` (MIT), `.gitignore` (exists — verify)

- [ ] **Step 1: Write the config version pins**

```bash
mkdir -p config
printf '4.4\n'        > config/kazoo.version
printf '26.2.5.20\n'  > config/otp.version
printf '3.24.0\n'     > config/rebar.version          # pinned (playbook fetched latest)
printf '1\n'          > config/package.revision
printf '1.10.9\n'     > config/freeswitch.version
printf '1.13.17\n'    > config/sofia-sip.version
printf '0d2e9b7\n'    > config/spandsp.ref             # PLACEHOLDER SHA — replace in Step 2
printf '4.4\n'        > config/mod_kazoo.ref
printf '5.8.8\n'      > config/kamailio.version
```

- [ ] **Step 2: Resolve the two unpinned refs to exact values**

The playbook left `rebar3` and `spandsp` unpinned. Pin them for reproducibility:

Run:
```bash
# Newest rebar3 3.x release tag:
git ls-remote --tags https://github.com/erlang/rebar3.git | grep -oE 'refs/tags/3\.[0-9.]+$' | sort -V | tail -1
# spandsp default-branch tip commit (freeswitch fork):
git ls-remote https://github.com/freeswitch/spandsp.git HEAD | cut -f1
```
Expected: a version like `3.24.0` and a 40-char SHA.
Write the real values into `config/rebar.version` and `config/spandsp.ref` (full SHA), replacing the placeholder.

- [ ] **Step 3: Write the Makefile**

```makefile
# Kazoo 4.4 full-stack Debian builder
# Top-level entrypoints. All real logic lives in scripts/*.sh.

SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -euo pipefail -c
.DEFAULT_GOAL  := help

KAZOO_VERSION       := $(shell cat config/kazoo.version)
OTP_VERSION         := $(shell cat config/otp.version)
REBAR_VERSION       := $(shell cat config/rebar.version)
PKG_REVISION        := $(shell cat config/package.revision)
FREESWITCH_VERSION  := $(shell cat config/freeswitch.version)
SOFIA_SIP_VERSION   := $(shell cat config/sofia-sip.version)
SPANDSP_REF         := $(shell cat config/spandsp.ref)
MOD_KAZOO_REF       := $(shell cat config/mod_kazoo.ref)
KAMAILIO_VERSION    := $(shell cat config/kamailio.version)

COMPONENT      ?=
ARCH           ?= $(shell uname -m)

VALID_COMPONENTS := erlang kazoo freeswitch kamailio
BUILD_DIR        := build
OUT_DIR          := $(BUILD_DIR)/out

export KAZOO_VERSION OTP_VERSION REBAR_VERSION PKG_REVISION \
       FREESWITCH_VERSION SOFIA_SIP_VERSION SPANDSP_REF MOD_KAZOO_REF KAMAILIO_VERSION

.PHONY: help
help:  ## Show available targets
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  COMPONENT=$(VALID_COMPONENTS)  (required for build)"
	@echo "  ARCH=amd64|arm64  (default: host)"

.PHONY: check-component
check-component:
	@if [ -z "$(COMPONENT)" ]; then echo "ERROR: COMPONENT required. One of: $(VALID_COMPONENTS)"; exit 2; fi
	@case " $(VALID_COMPONENTS) " in *" $(COMPONENT) "*) ;; \
	  *) echo "ERROR: COMPONENT=$(COMPONENT) invalid. One of: $(VALID_COMPONENTS)"; exit 2 ;; esac

.PHONY: docker-build
docker-build:  ## Build the Debian 12 build image
	docker build \
	  --build-arg OTP_VERSION=$(OTP_VERSION) \
	  --build-arg REBAR_VERSION=$(REBAR_VERSION) \
	  -t openkazoo-kazoo4-builder:debian-12 \
	  -f docker/Dockerfile.debian-12 .

.PHONY: build
build: check-component docker-build  ## Build COMPONENT into $(OUT_DIR)
	mkdir -p $(OUT_DIR)
	docker run --rm -v $(CURDIR):/work \
	  -e KAZOO_VERSION -e OTP_VERSION -e REBAR_VERSION -e PKG_REVISION \
	  -e FREESWITCH_VERSION -e SOFIA_SIP_VERSION -e SPANDSP_REF -e MOD_KAZOO_REF -e KAMAILIO_VERSION \
	  openkazoo-kazoo4-builder:debian-12 \
	  /work/scripts/build-$(COMPONENT).sh

.PHONY: sign
sign:  ## Sign all built debs (GPG_PRIVATE_KEY in env, or tests/fixtures/gpg/)
	./scripts/sign.sh

.PHONY: publish
publish:  ## Assemble the apt repo under build/repo/ from build/out/
	./scripts/publish.sh

.PHONY: test
test:  ## Run bats unit tests
	./tests/bats/bin/bats tests/unit/

.PHONY: clean
clean:  ## Remove build outputs
	rm -rf $(BUILD_DIR)
```

- [ ] **Step 4: Write LICENSE (MIT) and verify .gitignore**

```bash
cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 cloudpbx / openkazoo community

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
grep -q '^build/' .gitignore || printf 'build/\nout/\n*.deb\n.DS_Store\n' > .gitignore
```

- [ ] **Step 5: Commit**

```bash
git add config Makefile LICENSE .gitignore
git commit -m "Add config version pins, Makefile, and repo metadata"
```

---

## Task 2: Shared shell library (`scripts/lib.sh`)

**Files:**
- Create: `scripts/lib.sh`
- Test: `tests/unit/lib.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/lib.bats
setup() { load '../../scripts/lib.sh'; }

@test "arch_normalize maps x86_64 to amd64" {
  run arch_normalize x86_64
  [ "$status" -eq 0 ]; [ "$output" = "amd64" ]
}
@test "arch_normalize maps aarch64 to arm64" {
  run arch_normalize aarch64
  [ "$output" = "arm64" ]
}
@test "arch_normalize passes through amd64/arm64" {
  run arch_normalize amd64; [ "$output" = "amd64" ]
  run arch_normalize arm64; [ "$output" = "arm64" ]
}
@test "arch_normalize rejects unknown arch" {
  run arch_normalize sparc; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/bats/bin/bats tests/unit/lib.bats`
Expected: FAIL — `scripts/lib.sh` does not exist (load fails).

- [ ] **Step 3: Write `scripts/lib.sh`**

```bash
#!/usr/bin/env bash
# lib.sh — shared helpers, sourced by every build/sign/publish script.

die() { echo "ERROR: $*" >&2; exit 2; }

# arch_normalize <raw> -> amd64|arm64 (accepts x86_64/aarch64/amd64/arm64)
arch_normalize() {
  case "$1" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "unknown arch: $1" >&2; return 1 ;;
  esac
}

# repo_root -> absolute path to the checkout (scripts/..)
repo_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

# write_deb_control <dir> <pkg> <version> <arch> <desc> [depends]
# Emits a minimal DEBIAN/control (mirrors the playbook's hand-written control).
write_deb_control() {
  local dir="$1" pkg="$2" ver="$3" arch="$4" desc="$5" depends="${6:-}"
  mkdir -p "$dir/DEBIAN"
  {
    echo "Package: $pkg"
    echo "Version: $ver"
    echo "Architecture: $arch"
    echo "Maintainer: openkazoo build <build@cloudpbx.example>"
    [ -n "$depends" ] && echo "Depends: $depends"
    echo "Description: $desc"
  } > "$dir/DEBIAN/control"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/lib.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/unit/lib.bats
git commit -m "Add shared shell lib with arch normalization + deb control helper"
```

---

## Task 3: bats test harness

**Files:**
- Create: `.gitmodules` (bats-core submodule), `tests/bats/`

- [ ] **Step 1: Add the bats-core submodule**

Run:
```bash
git submodule add https://github.com/bats-core/bats-core.git tests/bats
git -C tests/bats checkout v1.11.0
```
Expected: `tests/bats/bin/bats` exists.

- [ ] **Step 2: Verify the harness runs the Task 2 test**

Run: `./tests/bats/bin/bats tests/unit/`
Expected: PASS (lib.bats tests green).

- [ ] **Step 3: Commit**

```bash
git add .gitmodules tests/bats
git commit -m "Vendor bats-core test harness as submodule"
```

---

## Task 4: Build image (`docker/Dockerfile.debian-12`)

**Files:**
- Create: `docker/Dockerfile.debian-12`

Ports the playbook's `bootstrap` apt list + kerl + rebar3. No AWS CLI (we publish to gh-pages).

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.6
# Build image for Kazoo 4.4 stack .deb packages (Debian 12 / bookworm).
# Built natively per-arch (amd64 or arm64) — no cross-compilation.
# Toolchain mirrors kazoo-deploy build-packages.yml `bootstrap` task.
FROM debian:12

ARG OTP_VERSION=26.2.5.20
ARG REBAR_VERSION=3.24.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf m4 libncurses-dev libssl-dev libssh-dev \
      unixodbc-dev xsltproc libxml2-utils flex bison make pkg-config \
      dpkg-dev debhelper apt-utils devscripts debsigs reprepro \
      gnupg git curl wget jq ca-certificates unzip golang \
      default-libmysqlclient-dev libcurl4-openssl-dev libpcre3-dev libpq-dev \
      libsqlite3-dev libedit-dev libtiff-dev liblua5.4-dev uuid-dev \
      libavformat-dev libswscale-dev libavcodec-dev libavutil-dev \
      libspeex-dev libspeexdsp-dev libopus-dev libvpx-dev yasm \
      libsndfile1-dev libldns-dev libmpg123-dev libmp3lame-dev libshout3-dev \
      libjpeg-dev libopenjp2-7-dev libuv1-dev libpng-dev libvorbis-dev libogg-dev \
      libpcre2-dev libevent-dev libgeoip-dev libjson-c-dev librabbitmq-dev \
 && rm -rf /var/lib/apt/lists/*

# Public repos only — rewrite any SSH GitHub URLs to HTTPS.
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"

# kerl (OTP version manager) + rebar3, both pinned.
RUN curl -fsSL --retry 5 --retry-all-errors \
      https://raw.githubusercontent.com/kerl/kerl/master/kerl -o /usr/local/bin/kerl \
 && chmod +x /usr/local/bin/kerl \
 && curl -fsSL --retry 5 --retry-all-errors \
      "https://github.com/erlang/rebar3/releases/download/${REBAR_VERSION}/rebar3" \
      -o /usr/local/bin/rebar3 \
 && chmod +x /usr/local/bin/rebar3

WORKDIR /work
```

- [ ] **Step 2: Verify the image builds (host arch)**

Run: `make docker-build`
Expected: image `openkazoo-kazoo4-builder:debian-12` builds without error.
(If Docker is unavailable locally, this is validated in CI — note that in the commit body.)

- [ ] **Step 3: Commit**

```bash
git add docker/Dockerfile.debian-12
git commit -m "Add Debian 12 build image with full toolchain, kerl, rebar3"
```

---

## Task 5: Erlang build script (`scripts/build-erlang.sh`)

**Files:**
- Create: `scripts/build-erlang.sh`
- Test: `tests/unit/build-erlang.bats`

Ports playbook L128-245. OTP 26.2.5.20 via kerl → `erlang` deb installing into `/usr/local/lib/erlang`.

- [ ] **Step 1: Write the failing test (control-file logic)**

```bash
# tests/unit/build-erlang.bats
setup() { load '../../scripts/lib.sh'; TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "erlang control declares Package: erlang and given version/arch" {
  write_deb_control "$TMP" erlang "26.2.5.20-1" amd64 "Erlang/OTP for Kazoo 4.4"
  grep -q '^Package: erlang$'        "$TMP/DEBIAN/control"
  grep -q '^Version: 26.2.5.20-1$'   "$TMP/DEBIAN/control"
  grep -q '^Architecture: amd64$'    "$TMP/DEBIAN/control"
}
```

- [ ] **Step 2: Run test to verify it passes (helper already exists)**

Run: `./tests/bats/bin/bats tests/unit/build-erlang.bats`
Expected: PASS — this test pins the control contract the script must satisfy.

- [ ] **Step 3: Write `scripts/build-erlang.sh`**

```bash
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
```

- [ ] **Step 4: Run the bats test again**

Run: `./tests/bats/bin/bats tests/unit/build-erlang.bats`
Expected: PASS. (The full kerl build is validated in CI — see Task 11.)

- [ ] **Step 5: Commit**

```bash
git add scripts/build-erlang.sh tests/unit/build-erlang.bats
git commit -m "Add erlang build script (kerl OTP 26.2.5.20 -> erlang deb)"
```

---

## Task 6: Kazoo build script (`scripts/build-kazoo.sh`)

**Files:**
- Create: `scripts/build-kazoo.sh`
- Test: `tests/unit/build-kazoo.bats`

Ports playbook L247-376. Clone `cloudpbx/openkazoo@4.4`, patch `include_erts=false`, `rebar3 compile && rebar3 tar` (default profile), wrap deb depending on `erlang`.

- [ ] **Step 1: Write the failing test (include_erts patch idempotency + version synth)**

```bash
# tests/unit/build-kazoo.bats
setup() {
  load '../../scripts/lib.sh'
  TMP="$(mktemp -d)"
  source "${BATS_TEST_DIRNAME}/../../scripts/build-kazoo.sh" --lib-only
}
teardown() { rm -rf "$TMP"; }

@test "patch_include_erts replaces true with false" {
  printf '{relx, [\n  {release, {kazoo, "4.4"}, []},\n  {include_erts, true}\n]}.\n' > "$TMP/rebar.config"
  patch_include_erts "$TMP/rebar.config"
  grep -q '{include_erts, false}' "$TMP/rebar.config"
  ! grep -q '{include_erts, true}' "$TMP/rebar.config"
}

@test "patch_include_erts inserts false when absent" {
  printf '{relx, [\n  {release, {kazoo, "4.4"}, []}\n]}.\n' > "$TMP/rebar.config"
  patch_include_erts "$TMP/rebar.config"
  grep -q '{include_erts, false}' "$TMP/rebar.config"
}

@test "synth_version produces base~branch.date.sha shape" {
  run synth_version 4.4 20260722 deadbeef
  [ "$output" = "4.4.0~4.4.20260722.deadbeef" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/bats/bin/bats tests/unit/build-kazoo.bats`
Expected: FAIL — script/functions do not exist.

- [ ] **Step 3: Write `scripts/build-kazoo.sh`**

```bash
#!/usr/bin/env bash
# build-kazoo.sh — build Kazoo 4.4 and wrap it into a `kazoo` .deb.
# Ports kazoo-deploy build-packages.yml L247-376.
#
# Uses `rebar3 compile && rebar3 tar` on the DEFAULT profile (as the playbook
# does): this sidesteps the openkazoo Makefile's `git describe --tags` release
# gate entirely, so no upstream tags are required and the source Makefile is
# left unmodified. Output tarball lands in _build/default/rel/kazoo/*.tar.gz.
# rebar.config is patched to include_erts=false so the deb depends on the
# separately-built `erlang` package rather than bundling ERTS.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Idempotent replace-or-insert of {include_erts, false} in a rebar.config.
patch_include_erts() {
  local f="$1"
  if grep -q 'include_erts' "$f"; then
    sed -i 's/{include_erts, true}/{include_erts, false}/g' "$f"
  else
    sed -i 's/{relx, \[/{relx, [\n  {include_erts, false},/' "$f"
  fi
}

# synth_version <branch> <yyyymmdd> <shortsha> -> 4.4.0~<branch>.<date>.<sha>
synth_version() { echo "4.4.0~${1}.${2}.${3}"; }

# Allow sourcing for tests without executing the build.
[ "${1:-}" = "--lib-only" ] && return 0

ROOT="$(repo_root)"
OUT="$ROOT/build/out"
SRC="$ROOT/build/kazoo-src"
STAGE="$ROOT/build/kazoo-deb"
ARCH="$(arch_normalize "$(uname -m)")"
mkdir -p "$OUT"

echo ">> Cloning cloudpbx/openkazoo@${KAZOO_VERSION:?}"
rm -rf "$SRC"
git clone --depth 1 --branch "$KAZOO_VERSION" \
  https://github.com/cloudpbx/openkazoo.git "$SRC"

SHORTSHA="$(git -C "$SRC" rev-parse --short=8 HEAD)"
TODAY="$(date -u +%Y%m%d)"
PKG_VERSION="$(synth_version "$KAZOO_VERSION" "$TODAY" "$SHORTSHA")-${PKG_REVISION:?}"
DEB="$OUT/kazoo_${PKG_VERSION}_${ARCH}.deb"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

echo ">> Patching include_erts=false"
patch_include_erts "$SRC/rebar.config"

export PATH="/usr/local/lib/erlang/bin:$PATH"
echo ">> rebar3 compile (hard gate)"
( cd "$SRC" && rebar3 compile )
echo ">> rebar3 tar"
( cd "$SRC" && rebar3 tar )

TARBALL="$(find "$SRC/_build/default/rel/kazoo" -maxdepth 1 -name '*.tar.gz' | head -1)"
[ -n "$TARBALL" ] || die "no release tarball in _build/default/rel/kazoo"

echo ">> Packaging kazoo deb: $DEB"
rm -rf "$STAGE"; mkdir -p "$STAGE/opt/kazoo"
tar -xzf "$TARBALL" -C "$STAGE/opt/kazoo"
write_deb_control "$STAGE" kazoo "$PKG_VERSION" "$ARCH" \
  "Kazoo 4.4 UCaaS platform (built against Erlang/OTP ${OTP_VERSION}, include_erts=false)" \
  "erlang (>= ${OTP_VERSION%%.*})"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/build-kazoo.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/build-kazoo.sh tests/unit/build-kazoo.bats
git commit -m "Add kazoo build script (openkazoo@4.4, include_erts=false, rebar3 default profile)"
```

---

## Task 7: FreeSWITCH build script (`scripts/build-freeswitch.sh`)

**Files:**
- Create: `scripts/build-freeswitch.sh`
- Test: `tests/unit/build-freeswitch.bats`

Ports playbook L378-612 — the highest-risk component. Carries the mod_kazoo overlay + `ei_skip_term ≥3` gate, the `-D_GNU_SOURCE` fix, sofia-sip/spandsp from source, and module disables. **Keep every explanatory comment.**

- [ ] **Step 1: Write the failing test (modules.conf edit logic)**

```bash
# tests/unit/build-freeswitch.bats
setup() {
  load '../../scripts/lib.sh'; TMP="$(mktemp -d)"
  source "${BATS_TEST_DIRNAME}/../../scripts/build-freeswitch.sh" --lib-only
}
teardown() { rm -rf "$TMP"; }

@test "configure_modules disables verto/signalwire/av/spandsp and enables mod_kazoo" {
  cat > "$TMP/modules.conf" <<EOF
endpoints/mod_verto
applications/mod_signalwire
applications/mod_av
applications/mod_spandsp
#event_handlers/mod_kazoo
EOF
  configure_modules "$TMP/modules.conf"
  grep -q '^#endpoints/mod_verto$'        "$TMP/modules.conf"
  grep -q '^#applications/mod_signalwire$' "$TMP/modules.conf"
  grep -q '^#applications/mod_av$'         "$TMP/modules.conf"
  grep -q '^#applications/mod_spandsp$'    "$TMP/modules.conf"
  grep -q '^event_handlers/mod_kazoo$'     "$TMP/modules.conf"
}

@test "assert_mod_kazoo_fix passes only with >=3 ei_skip_term" {
  printf 'ei_skip_term\nei_skip_term\nei_skip_term\n' > "$TMP/kazoo_node.c"
  run assert_mod_kazoo_fix "$TMP/kazoo_node.c"; [ "$status" -eq 0 ]
  printf 'ei_skip_term\n' > "$TMP/kazoo_node.c"
  run assert_mod_kazoo_fix "$TMP/kazoo_node.c"; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/bats/bin/bats tests/unit/build-freeswitch.bats`
Expected: FAIL — script/functions do not exist.

- [ ] **Step 3: Write `scripts/build-freeswitch.sh`**

```bash
#!/usr/bin/env bash
# build-freeswitch.sh — build FreeSWITCH 1.10.9 + mod_kazoo into a `freeswitch` .deb.
# Ports kazoo-deploy build-packages.yml L378-612.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Disable SignalWire/FFmpeg4-incompatible modules; ensure mod_kazoo enabled.
configure_modules() {
  local f="$1"
  sed -i -E 's,^(endpoints/mod_verto|applications/mod_signalwire|applications/mod_av|applications/mod_spandsp)$,#\1,' "$f"
  if grep -qE '^#?event_handlers/mod_kazoo' "$f"; then
    sed -i -E 's,^#?event_handlers/mod_kazoo.*,event_handlers/mod_kazoo,' "$f"
  else
    echo 'event_handlers/mod_kazoo' >> "$f"
  fi
}

# FS 1.10.9's bundled mod_kazoo decodes the $gen_call reply tag with
# ei_decode_ref, which fails on OTP 24+ where gen:do_call sends [alias|Mref].
# The openkazoo overlay uses ei_skip_term (opaque bytes) in 3 places.
assert_mod_kazoo_fix() {
  local n; n="$(grep -c ei_skip_term "$1" || true)"
  [ "${n:-0}" -ge 3 ] || die "mod_kazoo alias-tag fix missing (ei_skip_term=$n, need >=3)"
}

[ "${1:-}" = "--lib-only" ] && return 0

ROOT="$(repo_root)"; OUT="$ROOT/build/out"; B="$ROOT/build"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${FREESWITCH_VERSION:?}-${PKG_REVISION:?}"
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
export PATH="/usr/local/lib/erlang/bin:$PATH"
( cd "$B/freeswitch" \
  && ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc \
       --with-openssl --enable-core-odbc-support --with-modules=mod_kazoo \
  && make -j"$(nproc)" CFLAGS="-Wno-error -D_GNU_SOURCE" \
  && make install )
[ -f /usr/lib/freeswitch/mod/mod_kazoo.so ] || die "mod_kazoo.so not built — ecallmgr would fail silently"

echo ">> Packaging freeswitch deb: $DEB"
STAGE="$B/freeswitch-deb"; rm -rf "$STAGE"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/etc/freeswitch" "$STAGE/var"
cp -a /usr/bin/freeswitch "$STAGE/usr/bin/"
# libfreeswitch.so* must live in /usr/lib (the binary's RUNPATH).
find /usr/lib -maxdepth 1 -name 'libfreeswitch.so*' -exec cp -a {} "$STAGE/usr/lib/" \;
[ -d /usr/lib/freeswitch ] && cp -a /usr/lib/freeswitch "$STAGE/usr/lib/"
cp -a /etc/freeswitch/. "$STAGE/etc/freeswitch/" 2>/dev/null || true
printf '#!/bin/sh\nldconfig\n' > "$STAGE/DEBIAN/postinst" 2>/dev/null || { mkdir -p "$STAGE/DEBIAN"; printf '#!/bin/sh\nldconfig\n' > "$STAGE/DEBIAN/postinst"; }
printf '#!/bin/sh\nldconfig\n' > "$STAGE/DEBIAN/postrm"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
write_deb_control "$STAGE" freeswitch "$VER" "$ARCH" \
  "FreeSWITCH ${FREESWITCH_VERSION} with mod_kazoo (OTP 24+ alias-tag fix)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/build-freeswitch.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/build-freeswitch.sh tests/unit/build-freeswitch.bats
git commit -m "Add freeswitch build script (mod_kazoo overlay, _GNU_SOURCE, sofia/spandsp from source)"
```

---

## Task 8: Kamailio build script (`scripts/build-kamailio.sh`)

**Files:**
- Create: `scripts/build-kamailio.sh`
- Test: `tests/unit/build-kamailio.bats`

Ports playbook L614-792 (both arch legs collapse into one arch-parameterized script).

- [ ] **Step 1: Write the failing test (control depends/arch)**

```bash
# tests/unit/build-kamailio.bats
setup() { load '../../scripts/lib.sh'; TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "kamailio control has correct package name and arch" {
  write_deb_control "$TMP" kamailio "5.8.8-1" arm64 "Kamailio 5.8.8 SIP proxy"
  grep -q '^Package: kamailio$'   "$TMP/DEBIAN/control"
  grep -q '^Architecture: arm64$' "$TMP/DEBIAN/control"
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/build-kamailio.bats`
Expected: PASS — pins the control contract.

- [ ] **Step 3: Write `scripts/build-kamailio.sh`**

```bash
#!/usr/bin/env bash
# build-kamailio.sh — build Kamailio 5.8.8 into a `kamailio` .deb.
# Ports kazoo-deploy build-packages.yml L614-792 (arch-parameterized).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"; OUT="$ROOT/build/out"; B="$ROOT/build"
ARCH="$(arch_normalize "$(uname -m)")"
VER="${KAMAILIO_VERSION:?}-${PKG_REVISION:?}"
DEB="$OUT/kamailio_${VER}_${ARCH}.deb"
mkdir -p "$OUT"
[ -f "$DEB" ] && { echo ">> $DEB exists — skipping"; exit 0; }

echo ">> Cloning kamailio ${KAMAILIO_VERSION}"
rm -rf "$B/kamailio"
git clone --depth 1 --branch "$KAMAILIO_VERSION" \
  https://github.com/kamailio/kamailio.git "$B/kamailio"

echo ">> Building kamailio (~30 min)"
( cd "$B/kamailio" \
  && make FLAVOUR=kamailio include_modules="db_mysql db_postgres tls kazoo rabbitmq" PREFIX=/usr cfg \
  && make -j"$(nproc)" \
  && make install )

echo ">> Packaging kamailio deb: $DEB"
STAGE="$B/kamailio-deb"; rm -rf "$STAGE"
mkdir -p "$STAGE/usr/sbin" "$STAGE/usr/lib/kamailio" "$STAGE/etc/kamailio"
cp -a /usr/sbin/kamailio "$STAGE/usr/sbin/" 2>/dev/null || true
cp -a /usr/lib/kamailio/. "$STAGE/usr/lib/kamailio/" 2>/dev/null || true
cp -a /etc/kamailio/. "$STAGE/etc/kamailio/" 2>/dev/null || true
write_deb_control "$STAGE" kamailio "$VER" "$ARCH" \
  "Kamailio ${KAMAILIO_VERSION} SIP proxy (db_mysql db_postgres tls kazoo rabbitmq)"
dpkg-deb --build "$STAGE" "$DEB"
rm -rf "$STAGE"
echo ">> Done: $DEB"; ls -la "$DEB"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/build-kamailio.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-kamailio.sh tests/unit/build-kamailio.bats
git commit -m "Add kamailio build script (5.8.8, kazoo+rabbitmq modules)"
```

---

## Task 9: Sign script (`scripts/sign.sh`)

**Files:**
- Create: `scripts/sign.sh`
- Test: `tests/unit/sign.bats`

Adapted from kazoo5-builder `scripts/sign.sh`, generalized to sign **all** debs (any component).

- [ ] **Step 1: Write the failing test (no-key error path)**

```bash
# tests/unit/sign.bats
@test "sign.sh fails clearly when no key source is available" {
  run env -u GPG_PRIVATE_KEY -u GNUPGHOME "${BATS_TEST_DIRNAME}/../../scripts/sign.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no key source"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/bats/bin/bats tests/unit/sign.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write `scripts/sign.sh`**

```bash
#!/usr/bin/env bash
# sign.sh — GPG-sign every built .deb with debsigs (origin role).
# Key source priority: $GPG_PRIVATE_KEY (CI) → $GNUPGHOME (local).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"; OUT="$ROOT/build/out"

if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
  TMP_GNUPGHOME="$(mktemp -d)"; trap 'rm -rf "$TMP_GNUPGHOME"' EXIT
  chmod 700 "$TMP_GNUPGHOME"; export GNUPGHOME="$TMP_GNUPGHOME"
  if [ -n "${GPG_PASSPHRASE:-}" ]; then
    echo "$GPG_PRIVATE_KEY" | gpg --batch --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" --import 2>&1 | tail -3
  else
    echo "$GPG_PRIVATE_KEY" | gpg --batch --import 2>&1 | tail -3
  fi
elif [ -n "${GNUPGHOME:-}" ] && [ -d "${GNUPGHOME:-/nonexistent}" ]; then
  echo ">> Using local GNUPGHOME=$GNUPGHOME"
else
  die "no key source: set GPG_PRIVATE_KEY or GNUPGHOME"
fi

FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || die "no secret key found in keyring"
echo ">> Signing with $FPR"

shopt -s nullglob
DEBS=("$OUT"/*.deb); shopt -u nullglob
[ "${#DEBS[@]}" -gt 0 ] || die "no .deb files in $OUT"
for deb in "${DEBS[@]}"; do
  echo ">> debsigs sign: $deb"
  debsigs --sign=origin --default-key="$FPR" "$deb"
done
echo ">> Signing complete."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/sign.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/sign.sh tests/unit/sign.bats
git commit -m "Add sign.sh (debsigs sign all built debs)"
```

---

## Task 10: Publish script (`scripts/publish.sh`)

**Files:**
- Create: `scripts/publish.sh`
- Test: `tests/unit/publish.bats`

Adapted from kazoo5-builder `scripts/publish.sh`: **reprepro** pooled apt repo, but **multi-arch** (`amd64 arm64`) and no yum path.

- [ ] **Step 1: Write the failing test (distributions file generation)**

```bash
# tests/unit/publish.bats
setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "write_distributions emits both architectures and SignWith" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  write_distributions "$TMP" "ABC123FPR"
  grep -q '^Architectures: amd64 arm64$' "$TMP/conf/distributions"
  grep -q '^Codename: bookworm$'          "$TMP/conf/distributions"
  grep -q '^SignWith: ABC123FPR$'          "$TMP/conf/distributions"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/bats/bin/bats tests/unit/publish.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write `scripts/publish.sh`**

```bash
#!/usr/bin/env bash
# publish.sh — assemble a signed, multi-arch pooled apt repo under build/repo/.
# Inputs: build/out/*.deb (any component, amd64 and/or arm64).
# Output: build/repo/{pool,dists}/... + build/repo/pubkey.asc
# Adapted from openkazoo-kazoo5-builder/scripts/publish.sh (reprepro), extended
# to Architectures: amd64 arm64 and dropping the yum path.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

write_distributions() {
  local apt_dir="$1" fpr="$2"
  mkdir -p "$apt_dir/conf"
  cat > "$apt_dir/conf/distributions" <<EOF
Origin: openkazoo
Label: openkazoo-kazoo4-builder
Suite: stable
Codename: bookworm
Architectures: amd64 arm64
Components: main
Description: Community-built Kazoo 4.4 stack for Debian 12
SignWith: $fpr
EOF
}

[ "${1:-}" = "--lib-only" ] && return 0

ROOT="$(repo_root)"
OUT="${OUT_DIR_OVERRIDE:-$ROOT/build/out}"
REPO="$ROOT/build/repo"; APT="$REPO/debian"

shopt -s nullglob; DEBS=("$OUT"/*.deb); shopt -u nullglob
[ "${#DEBS[@]}" -gt 0 ] || die "no packages in $OUT; run 'make build' first"

if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
  TMP_GNUPGHOME="$(mktemp -d)"; trap 'rm -rf "$TMP_GNUPGHOME"' EXIT
  chmod 700 "$TMP_GNUPGHOME"; export GNUPGHOME="$TMP_GNUPGHOME"
  echo "$GPG_PRIVATE_KEY" | gpg --batch --import 2>&1 | tail -3
fi
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || die "no GPG key available"

mkdir -p "$REPO"
gpg --armor --export "$FPR" > "$REPO/pubkey.asc"
write_distributions "$APT" "$FPR"
for deb in "${DEBS[@]}"; do
  echo ">> reprepro includedeb bookworm: $deb"
  reprepro -b "$APT" includedeb bookworm "$deb"
done

cat > "$REPO/README.md" <<'EOF'
# openkazoo-kazoo4-builder package repository
This `gh-pages` branch hosts the apt repository for the Kazoo 4.4 stack.
See docs/INSTALL.md in the main branch. Public signing key: `pubkey.asc`.
EOF
echo ">> Published under: $REPO"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/unit/publish.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish.sh tests/unit/publish.bats
git commit -m "Add publish.sh (reprepro multi-arch pooled apt repo)"
```

---

## Task 11: Build/publish CI workflow (`.github/workflows/build.yml`)

**Files:**
- Create: `.github/workflows/build.yml`

Matrix `component × arch` on native runners. `workflow_dispatch` with `publish` input for dry-runs; tag push publishes + releases.

- [ ] **Step 1: Write the workflow**

```yaml
name: build
on:
  push:
    tags: ['v4.*']
  workflow_dispatch:
    inputs:
      publish:
        description: 'Publish to gh-pages + create Release'
        type: boolean
        default: false

permissions:
  contents: write   # create releases + push gh-pages

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        component: [erlang, kazoo, freeswitch, kamailio]
        arch: [amd64, arm64]
    runs-on: ${{ matrix.arch == 'arm64' && 'ubuntu-24.04-arm' || 'ubuntu-24.04' }}
    steps:
      - uses: actions/checkout@v4
        with: { submodules: true }
      - name: Build ${{ matrix.component }} (${{ matrix.arch }})
        run: make build COMPONENT=${{ matrix.component }}
      - name: Sign
        if: ${{ inputs.publish || startsWith(github.ref, 'refs/tags/') }}
        env:
          GPG_PRIVATE_KEY: ${{ secrets.GPG_PRIVATE_KEY }}
          GPG_PASSPHRASE:  ${{ secrets.GPG_PASSPHRASE }}
        run: |
          docker run --rm -v "$PWD":/work \
            -e GPG_PRIVATE_KEY -e GPG_PASSPHRASE \
            openkazoo-kazoo4-builder:debian-12 /work/scripts/sign.sh
      - uses: actions/upload-artifact@v4
        with:
          name: deb-${{ matrix.component }}-${{ matrix.arch }}
          path: build/out/*.deb

  publish:
    needs: build
    if: ${{ inputs.publish || startsWith(github.ref, 'refs/tags/') }}
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with: { submodules: true }
      - uses: actions/download-artifact@v4
        with: { path: _artifacts }
      - name: Collect debs into build/out/
        run: |
          mkdir -p build/out
          find _artifacts -name '*.deb' -exec cp {} build/out/ \;
          ls -la build/out
      - name: Assemble apt repo
        env:
          GPG_PRIVATE_KEY: ${{ secrets.GPG_PRIVATE_KEY }}
          GPG_PASSPHRASE:  ${{ secrets.GPG_PASSPHRASE }}
        run: |
          make docker-build
          docker run --rm -v "$PWD":/work \
            -e GPG_PRIVATE_KEY -e GPG_PASSPHRASE \
            openkazoo-kazoo4-builder:debian-12 /work/scripts/publish.sh
      - name: Deploy to gh-pages
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: build/repo
      - name: Create Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: build/out/*.deb
```

- [ ] **Step 2: Lint the workflow YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml'))" && echo OK`
Expected: `OK` (valid YAML).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "Add build/publish CI workflow (matrix component x arch, dry-run input)"
```

---

## Task 12: Install-verification workflow (`.github/workflows/verify-install.yml`)

**Files:**
- Create: `.github/workflows/verify-install.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: verify-install
on:
  workflow_run:
    workflows: [build]
    types: [completed]
  workflow_dispatch:

jobs:
  verify:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    strategy:
      fail-fast: false
      matrix:
        arch: [amd64, arm64]
    runs-on: ${{ matrix.arch == 'arm64' && 'ubuntu-24.04-arm' || 'ubuntu-24.04' }}
    container: debian:12
    steps:
      - name: Add repo + install
        run: |
          set -euo pipefail
          apt-get update && apt-get install -y curl ca-certificates gnupg
          curl -fsSL https://cloudpbx.github.io/openkazoo-kazoo4-builder/pubkey.asc \
            | tee /usr/share/keyrings/openkazoo.asc > /dev/null
          echo "deb [signed-by=/usr/share/keyrings/openkazoo.asc] \
            https://cloudpbx.github.io/openkazoo-kazoo4-builder bookworm main" \
            > /etc/apt/sources.list.d/openkazoo.list
          apt-get update
          apt-get install -y kazoo freeswitch kamailio
      - name: Smoke-test artifacts present
        run: |
          set -euo pipefail
          test -d /opt/kazoo
          test -f /usr/lib/freeswitch/mod/mod_kazoo.so
          command -v kamailio
          /usr/local/lib/erlang/bin/erl -eval 'io:format("~s~n",[erlang:system_info(otp_release)]),halt().' -noshell | grep -q '^26'
```

- [ ] **Step 2: Lint the workflow YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/verify-install.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/verify-install.yml
git commit -m "Add verify-install workflow (apt install + smoke test, both arches)"
```

---

## Task 13: Documentation (README, STATUS, INSTALL, ARCHITECTURE, CONTRIBUTING, GPG-KEY)

**Files:**
- Create: `README.md`, `STATUS.md`, `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, `docs/CONTRIBUTING.md`, `docs/GPG-KEY.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# openkazoo-kazoo4-builder

Community-built Debian 12 (bookworm) packages for the **Kazoo 4.4** telephony
stack — `erlang`, `kazoo`, `freeswitch`, `kamailio` — for **amd64 and arm64**.

Source of truth for the recipe: the `kazoo-deploy` `build-packages.yml` playbook.
Structure modeled on [`openkazoo-kazoo5-builder`](https://github.com/cloudpbx/openkazoo-kazoo5-builder).

## Install
See [docs/INSTALL.md](docs/INSTALL.md).

## Build locally
```bash
make build COMPONENT=erlang       # or kazoo | freeswitch | kamailio
make sign && make publish         # requires GPG_PRIVATE_KEY
make test                         # bats unit tests
```

## License
MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Write `docs/INSTALL.md`** (end-user apt instructions)

```markdown
# Installing the Kazoo 4.4 stack

```bash
curl -fsSL https://cloudpbx.github.io/openkazoo-kazoo4-builder/pubkey.asc \
  | sudo tee /usr/share/keyrings/openkazoo.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/openkazoo.asc] \
https://cloudpbx.github.io/openkazoo-kazoo4-builder bookworm main" \
  | sudo tee /etc/apt/sources.list.d/openkazoo.list
sudo apt-get update
sudo apt-get install -y kazoo freeswitch kamailio   # erlang pulled in as a dependency
```

Supported: Debian 12 (bookworm), amd64 and arm64.
```

- [ ] **Step 3: Write `docs/ARCHITECTURE.md`, `docs/CONTRIBUTING.md`**

`ARCHITECTURE.md` documents: the 4 components + versions, the build image, the
per-component script flow, the reprepro apt repo layout, the CI matrix, and a
pointer to the design spec. `CONTRIBUTING.md`: how to bump a `config/` pin, run
`make test`, and open a PR. (Prose only — no code contract to pin here.)

- [ ] **Step 4: Write `docs/GPG-KEY.md`** (maintainer key setup)

```markdown
# Signing key setup

The CI signs packages with a GPG key stored in repo secrets.

1. Generate an ed25519 signing key (no passphrase for CI, or set GPG_PASSPHRASE):
   `gpg --batch --quick-generate-key "openkazoo build <build@cloudpbx.example>" ed25519 sign 2y`
2. Export the private key:
   `gpg --armor --export-secret-keys <FPR>`
3. In the repo: Settings → Secrets → Actions → add `GPG_PRIVATE_KEY`
   (and `GPG_PASSPHRASE` if the key has one).
4. The public key is published automatically as `pubkey.asc` at the site root.
```

- [ ] **Step 5: Write `STATUS.md`** (initial state + the OTP-27 wall + risk register)

```markdown
# Project Status

**Status:** scaffolding complete; first CI dry-run pending.

## Scope
Full Kazoo 4.4 stack (erlang, kazoo, freeswitch, kamailio) as signed Debian 12
.debs for amd64 + arm64, published to GitHub Pages apt repo.

## Key constraints
- **OTP 26.2.5.20 is the target and the ceiling.** Kazoo 4.4 requires OTP 26+;
  OTP 27 hit a mod_kazoo <-> ecallmgr app-protocol wall. Do not bump past 26
  while FreeSWITCH is in scope.
- FreeSWITCH pinned to 1.10.9 (1.10.12+ dropped mod_kazoo); mod_kazoo overlaid
  from openkazoo/freeswitch-mod_kazoo@4.4 (OTP 24+ alias-tag fix).

## Open risks
- Repo is private → confirm arm64 runner + Pages billing, or make public.
- arm64 FreeSWITCH/sofia/spandsp unproven (playbook is amd64-only).
- First green will take several `publish=false` dry-runs (kazoo5 took 11).
```

- [ ] **Step 6: Commit**

```bash
git add README.md STATUS.md docs/INSTALL.md docs/ARCHITECTURE.md docs/CONTRIBUTING.md docs/GPG-KEY.md
git commit -m "Add README, STATUS, and docs (install, architecture, contributing, GPG key)"
```

---

## Task 14: Push to origin + first dry-run

**Files:** none (repo operations)

- [ ] **Step 1: Confirm the tree and run the full unit suite**

Run: `make test`
Expected: all bats tests PASS.

- [ ] **Step 2: Push `main` to the existing remote**

Run:
```bash
git push -u origin main
```
Expected: branch `main` created on `cloudpbx/openkazoo-kazoo4-builder`.

- [ ] **Step 3: Maintainer sets secrets, then trigger a dry-run**

Prerequisite (maintainer, per `docs/GPG-KEY.md`): set `GPG_PRIVATE_KEY` (+ optional `GPG_PASSPHRASE`).
Then trigger the build workflow with `publish=false` (Actions → build → Run workflow) and iterate on failures — expect several rounds (document each fix in a commit, kazoo5-style). Highest-risk leg: `freeswitch × arm64`.

- [ ] **Step 4: First real release**

Once a dry-run is green end-to-end:
```bash
git tag "v4.4.0-$(date -u +%Y%m%d)-1"
git push origin "v4.4.0-$(date -u +%Y%m%d)-1"
```
Expected: build → sign → gh-pages publish → GitHub Release with all `.deb`s.

---

## Self-Review (completed during authoring)

**Spec coverage:** erlang (T5), kazoo+include_erts (T6), freeswitch+mod_kazoo/_GNU_SOURCE/sofia/spandsp/module-disables (T7), kamailio (T8), OTP-26-ceiling (T5 comment + STATUS), gh-pages apt/multi-arch (T10), GPG signing (T9/T13), CI matrix + dry-run (T11), verify-install (T12), config pins incl. rebar/spandsp pinning (T1), docs + risks (T13). All spec sections map to a task.

**Placeholder scan:** the only intentional placeholder is `config/spandsp.ref`, explicitly resolved to a real SHA in T1 Step 2 before use.

**Type/name consistency:** `arch_normalize`, `write_deb_control`, `repo_root` (lib.sh) are used with matching signatures across T5–T10; `patch_include_erts`/`synth_version` (T6), `configure_modules`/`assert_mod_kazoo_fix` (T7), `write_distributions` (T10) are each defined and tested in their own task and used consistently.
```
