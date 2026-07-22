# Contributing

## Bumping a version pin

All versions live in `config/` (one value per file). To change one:

1. Edit the relevant file, e.g. `config/kamailio.version`.
2. Run `make test` (bats units must stay green).
3. Trigger a `publish=false` dry-run of the `build` workflow and confirm the
   affected component builds.
4. Open a PR describing the bump and linking the dry-run.

**Do not** raise `config/otp.version` past major `26` — Kazoo 4.4 requires
OTP 26+, and OTP 27 breaks the `mod_kazoo` ↔ `ecallmgr` protocol (see
[ARCHITECTURE.md](ARCHITECTURE.md)).

## Running tests

```bash
make test          # runs tests/unit/*.bats via the vendored bats-core
```

New shell logic should get a bats test in `tests/unit/`. Keep test temp files
in bats' built-in `$BATS_TEST_TMPDIR` (do not call `mktemp`). Keep shell
portable across GNU sed (build container) and BSD sed (macOS): avoid `sed -i`
and `\n`-in-replacement — write to a temp file and `mv`, or use `awk`.

## Editing build scripts

- Each `scripts/build-<component>.sh` is a port of a section of the
  `kazoo-deploy` `build-packages.yml` playbook. **Preserve the explanatory
  comments** — they document real crashes and non-obvious fixes.
- Scripts source `scripts/lib.sh` for shared helpers (`die`,
  `arch_normalize`, `repo_root`, `write_deb_control`).

## PRs

Keep them small and focused; explain the *why*, not just the *what*. Ensure
`make test` and the CI dry-run pass before requesting review.
