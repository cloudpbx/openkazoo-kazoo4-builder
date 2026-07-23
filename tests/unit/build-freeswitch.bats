setup() {
  load '../../scripts/lib.sh'
  TMP="$BATS_TEST_TMPDIR"
  source "${BATS_TEST_DIRNAME}/../../scripts/build-freeswitch.sh" --lib-only
}

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
