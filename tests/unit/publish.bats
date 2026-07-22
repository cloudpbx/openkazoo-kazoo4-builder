setup() { TMP="$BATS_TEST_TMPDIR"; }

@test "write_distributions emits both architectures and SignWith" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  write_distributions "$TMP" "ABC123FPR"
  grep -q '^Architectures: amd64 arm64$' "$TMP/conf/distributions"
  grep -q '^Codename: bookworm$'          "$TMP/conf/distributions"
  grep -q '^SignWith: ABC123FPR$'          "$TMP/conf/distributions"
}
