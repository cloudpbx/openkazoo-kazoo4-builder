setup() {
  load '../../scripts/lib.sh'
  TMP="$BATS_TEST_TMPDIR"
  source "${BATS_TEST_DIRNAME}/../../scripts/build-freeswitch.sh" --lib-only
}

@test "configure_modules disables incompatibles, keeps spandsp, and enables kazoo/opus/http_cache/shout" {
  cat > "$TMP/modules.conf" <<EOF
endpoints/mod_verto
applications/mod_signalwire
applications/mod_av
applications/mod_spandsp
#event_handlers/mod_kazoo
#codecs/mod_opus
#applications/mod_http_cache
#formats/mod_shout
EOF
  configure_modules "$TMP/modules.conf"
  # incompatible modules disabled
  grep -q '^#endpoints/mod_verto$'        "$TMP/modules.conf"
  grep -q '^#applications/mod_signalwire$' "$TMP/modules.conf"
  grep -q '^#applications/mod_av$'         "$TMP/modules.conf"
  # mod_spandsp stays enabled (built with the 76458fa V.18 patch)
  grep -q '^applications/mod_spandsp$'     "$TMP/modules.conf"
  ! grep -q '^#applications/mod_spandsp$'  "$TMP/modules.conf"
  # required modules enabled (uncommented, no leading #)
  grep -q '^event_handlers/mod_kazoo$'     "$TMP/modules.conf"
  grep -q '^codecs/mod_opus$'              "$TMP/modules.conf"
  grep -q '^applications/mod_http_cache$'  "$TMP/modules.conf"
  grep -q '^formats/mod_shout$'            "$TMP/modules.conf"
  ! grep -q '^#applications/mod_http_cache$' "$TMP/modules.conf"
  ! grep -q '^#formats/mod_shout$'          "$TMP/modules.conf"
}

@test "configure_modules appends a required module when absent from modules.conf" {
  printf 'endpoints/mod_sofia\n' > "$TMP/modules.conf"
  configure_modules "$TMP/modules.conf"
  grep -q '^applications/mod_http_cache$' "$TMP/modules.conf"
  grep -q '^formats/mod_shout$'           "$TMP/modules.conf"
}

@test "assert_mod_kazoo_fix passes only with >=3 ei_skip_term" {
  printf 'ei_skip_term\nei_skip_term\nei_skip_term\n' > "$TMP/kazoo_node.c"
  run assert_mod_kazoo_fix "$TMP/kazoo_node.c"; [ "$status" -eq 0 ]
  printf 'ei_skip_term\n' > "$TMP/kazoo_node.c"
  run assert_mod_kazoo_fix "$TMP/kazoo_node.c"; [ "$status" -ne 0 ]
}

@test "assert_mod_spandsp_v18_fix passes only with handle_v18_status" {
  printf 'static void handle_v18_status(void *user_data, int status)\n' > "$TMP/mod_spandsp_dsp.c"
  run assert_mod_spandsp_v18_fix "$TMP/mod_spandsp_dsp.c"; [ "$status" -eq 0 ]
  printf 'v18_init(NULL, TRUE, mode, V18_AUTOMODING_GLOBAL, put_text_msg, tdd);\n' > "$TMP/mod_spandsp_dsp.c"
  run assert_mod_spandsp_v18_fix "$TMP/mod_spandsp_dsp.c"; [ "$status" -ne 0 ]
}
