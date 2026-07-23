setup() { load '../../scripts/lib.sh'; TMP="$BATS_TEST_TMPDIR"; }

@test "kamailio control has correct package name and arch" {
  write_deb_control "$TMP" kamailio "5.8.8-1" arm64 "Kamailio 5.8.8 SIP proxy"
  grep -q '^Package: kamailio$'   "$TMP/DEBIAN/control"
  grep -q '^Architecture: arm64$' "$TMP/DEBIAN/control"
}
