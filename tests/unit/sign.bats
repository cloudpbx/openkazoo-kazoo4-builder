@test "sign.sh fails clearly when no key source is available" {
  run env -u GPG_PRIVATE_KEY -u GNUPGHOME "${BATS_TEST_DIRNAME}/../../scripts/sign.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no key source"* ]]
}
