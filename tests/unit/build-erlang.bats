setup() { load '../../scripts/lib.sh'; mkdir -p "$BATS_TEST_DIRNAME/.tmp"; TMP="$(mktemp -d "$BATS_TEST_DIRNAME/.tmp/XXXXXX")"; }
teardown() { rm -rf "$TMP"; }

@test "erlang control declares Package: erlang and given version/arch" {
  write_deb_control "$TMP" erlang "26.2.5.20-1" amd64 "Erlang/OTP for Kazoo 4.4"
  grep -q '^Package: erlang$'        "$TMP/DEBIAN/control"
  grep -q '^Version: 26.2.5.20-1$'   "$TMP/DEBIAN/control"
  grep -q '^Architecture: amd64$'    "$TMP/DEBIAN/control"
}
