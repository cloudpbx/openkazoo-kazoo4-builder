setup() { TMP="$BATS_TEST_TMPDIR"; }

@test "write_distributions emits bullseye + bookworm stanzas with arches and SignWith" {
  source "${BATS_TEST_DIRNAME}/../../scripts/publish.sh" --lib-only
  write_distributions "$TMP" "ABC123FPR"
  grep -q '^Codename: bullseye$'          "$TMP/conf/distributions"
  grep -q '^Codename: bookworm$'          "$TMP/conf/distributions"
  [ "$(grep -c '^Architectures: amd64 arm64$' "$TMP/conf/distributions")" -eq 2 ]
  [ "$(grep -c '^SignWith: ABC123FPR$' "$TMP/conf/distributions")" -eq 2 ]
}
