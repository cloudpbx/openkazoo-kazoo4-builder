# openkazoo-kazoo4-builder

Community-built **Debian 11 (bullseye)** and **Debian 12 (bookworm)** packages
for the **Kazoo 4.4** telephony stack — `erlang`, `kazoo`, `freeswitch`,
`kamailio` — for **amd64 and arm64**.

Source of truth for the build recipe: the `kazoo-deploy` `build-packages.yml`
playbook. Repository structure modeled on
[`openkazoo-kazoo5-builder`](https://github.com/cloudpbx/openkazoo-kazoo5-builder).

**Status:** scaffolding complete; first CI dry-run pending. See [STATUS.md](STATUS.md).

## Install

See [docs/INSTALL.md](docs/INSTALL.md) for end-user apt instructions.

## Build locally

```bash
make build COMPONENT=erlang DISTRO=debian-12   # DISTRO=debian-11|debian-12|debian-13 (default debian-12)
                                               # COMPONENT=erlang|kazoo|freeswitch|kamailio
make sign                         # requires GPG_PRIVATE_KEY (see docs/GPG-KEY.md)
make publish                      # assembles the apt repo (both suites) under build/repo/
make test                         # bats unit tests
make help                         # list all targets
```

Each component builds natively for the host architecture inside the selected
Debian build image (`docker/Dockerfile.debian-11` or `docker/Dockerfile.debian-12`).

## How it fits together

- `config/` — version pins (single source of truth).
- `docker/Dockerfile.debian-11`, `docker/Dockerfile.debian-12` — build images (kerl, rebar3, full toolchain).
- `scripts/build-*.sh` — one per component; ports of the playbook recipe.
- `scripts/sign.sh`, `scripts/publish.sh` — GPG signing + reprepro apt repo.
- `.github/workflows/` — matrix CI (`component × arch`) → sign → gh-pages → Release.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the
[design spec](docs/superpowers/specs/2026-07-22-kazoo4-fullstack-debian-builder-design.md).

> **No video support** — the FreeSWITCH package is built without VP8/VP9 codecs
> (audio telephony only). This is a deliberate scope decision; see
> [docs/DECISIONS.md](docs/DECISIONS.md) (D-01).

## License

MIT — see [LICENSE](LICENSE).
