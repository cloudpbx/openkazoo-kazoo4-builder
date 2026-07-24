# Kazoo 4.4 full-stack Debian builder
# Top-level entrypoints. All real logic lives in scripts/*.sh.

SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -euo pipefail -c
.DEFAULT_GOAL  := help

KAZOO_VERSION       := $(shell cat config/kazoo.version)
OTP_VERSION         := $(shell cat config/otp.version)
REBAR_VERSION       := $(shell cat config/rebar.version)
GO_VERSION          := $(shell cat config/go.version)
PKG_REVISION        := $(shell cat config/package.revision)
FREESWITCH_VERSION  := $(shell cat config/freeswitch.version)
SOFIA_SIP_VERSION   := $(shell cat config/sofia-sip.version)
SPANDSP_REF         := $(shell cat config/spandsp.ref)
MOD_KAZOO_REF       := $(shell cat config/mod_kazoo.ref)
KAMAILIO_VERSION    := $(shell cat config/kamailio.version)

COMPONENT      ?=
ARCH           ?= $(shell uname -m)
DISTRO         ?= debian-12

VALID_COMPONENTS := erlang kazoo freeswitch kamailio
VALID_DISTROS    := debian-11 debian-12
IMAGE            := openkazoo-kazoo4-builder:$(DISTRO)
BUILD_DIR        := build
OUT_DIR          := $(BUILD_DIR)/out

export KAZOO_VERSION OTP_VERSION REBAR_VERSION PKG_REVISION \
       FREESWITCH_VERSION SOFIA_SIP_VERSION SPANDSP_REF MOD_KAZOO_REF KAMAILIO_VERSION \
       DISTRO

.PHONY: help
help:  ## Show available targets
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  COMPONENT=$(VALID_COMPONENTS)  (required for build)"
	@echo "  DISTRO=$(VALID_DISTROS)  (default: debian-12)"
	@echo "  ARCH=amd64|arm64  (default: host)"

.PHONY: check-component
check-component:
	@if [ -z "$(COMPONENT)" ]; then echo "ERROR: COMPONENT required. One of: $(VALID_COMPONENTS)"; exit 2; fi
	@case " $(VALID_COMPONENTS) " in *" $(COMPONENT) "*) ;; \
	  *) echo "ERROR: COMPONENT=$(COMPONENT) invalid. One of: $(VALID_COMPONENTS)"; exit 2 ;; esac

.PHONY: check-distro
check-distro:
	@case " $(VALID_DISTROS) " in *" $(DISTRO) "*) ;; \
	  *) echo "ERROR: DISTRO=$(DISTRO) invalid. One of: $(VALID_DISTROS)"; exit 2 ;; esac

.PHONY: docker-build
docker-build: check-distro  ## Build the $(DISTRO) build image
	docker build \
	  --build-arg OTP_VERSION=$(OTP_VERSION) \
	  --build-arg REBAR_VERSION=$(REBAR_VERSION) \
	  --build-arg GO_VERSION=$(GO_VERSION) \
	  -t $(IMAGE) \
	  -f docker/Dockerfile.$(DISTRO) .

.PHONY: build
build: check-component docker-build  ## Build COMPONENT for DISTRO into $(OUT_DIR)
	mkdir -p $(OUT_DIR)
	docker run --rm -v $(CURDIR):/work \
	  -e KAZOO_VERSION -e OTP_VERSION -e REBAR_VERSION -e PKG_REVISION \
	  -e FREESWITCH_VERSION -e SOFIA_SIP_VERSION -e SPANDSP_REF -e MOD_KAZOO_REF -e KAMAILIO_VERSION \
	  -e DISTRO \
	  $(IMAGE) \
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
