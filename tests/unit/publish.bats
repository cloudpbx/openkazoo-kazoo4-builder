setup() { TMP="$BATS_TEST_TMPDIR"; }

@test "write_distributions emits bullseye + bookworm stanzas with arches and SignWith" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  write_distributions "$TMP" "ABC123FPR"
  grep -q '^Codename: bullseye$'          "$TMP/conf/distributions"
  grep -q '^Codename: bookworm$'          "$TMP/conf/distributions"
  [ "$(grep -c '^Architectures: amd64 arm64$' "$TMP/conf/distributions")" -eq 2 ]
  [ "$(grep -c '^SignWith: ABC123FPR$' "$TMP/conf/distributions")" -eq 2 ]
}

# Stand in for reprepro. freeswitch is deliberately amd64-only so the tests can
# tell "reported what shipped" apart from "echoed the build matrix".
fake_reprepro() {
  reprepro() {
    case "${!#}" in
      bookworm) printf '%s\n' \
        'bookworm|main|arm64: kazoo 4.4.0~4.4.1-4~bookworm' \
        'bookworm|main|amd64: kazoo 4.4.0~4.4.1-4~bookworm' \
        'bookworm|main|amd64: erlang 1:26.2.5.20-4~bookworm' \
        'bookworm|main|arm64: erlang 1:26.2.5.20-4~bookworm' \
        'bookworm|main|amd64: freeswitch 1.10.9-4~bookworm' ;;
      bullseye) printf '%s\n' \
        'bullseye|main|amd64: erlang 1:26.2.5.20-4~bullseye' ;;
    esac
  }
}

@test "published_rows keeps the version epoch and folds arches into one row" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  fake_reprepro
  run published_rows "$TMP"
  [ "$status" -eq 0 ]
  # epoch colon must survive the ": " split
  [[ "$output" == *"erlang	1:26.2.5.20-4~bookworm	amd64,arm64"* ]]
  # one row per package+suite, not one per arch
  [ "$(printf '%s\n' "$output" | grep -c 'bookworm	erlang')" -eq 1 ]
}

@test "published_rows reports the arches actually published, not the matrix" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  fake_reprepro
  run published_rows "$TMP"
  [[ "$output" == *"freeswitch	1.10.9-4~bookworm	amd64"* ]]
  [[ "$output" != *"freeswitch	1.10.9-4~bookworm	amd64,arm64"* ]]
}

@test "write_index_html emits a titled page listing every published package" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  fake_reprepro
  write_index_html "$TMP" "$TMP" > "$TMP/index.html"
  grep -q '<!doctype html>'                    "$TMP/index.html"
  grep -q '<title>.*apt repository</title>'    "$TMP/index.html"
  grep -q 'bullseye'                           "$TMP/index.html"
  grep -q 'bookworm'                           "$TMP/index.html"
  grep -q '1:26.2.5.20-4~bookworm'             "$TMP/index.html"
  # the install snippet must keep $VERSION_CODENAME unexpanded for copy-paste
  grep -q '\${VERSION_CODENAME}'               "$TMP/index.html"
  # and must not leak an empty row when a suite has packages
  ! grep -q '<tr><td><code></code></td>'       "$TMP/index.html"
}
