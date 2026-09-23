setup() {
  load '../../scripts/lib.sh'
  TMP="$BATS_TEST_TMPDIR"
  source "${BATS_TEST_DIRNAME}/../../scripts/build-kazoo.sh" --lib-only
}

@test "patch_include_erts replaces true with false" {
  printf '{relx, [\n  {release, {kazoo, "4.4"}, []},\n  {include_erts, true}\n]}.\n' > "$TMP/rebar.config"
  patch_include_erts "$TMP/rebar.config"
  grep -q '{include_erts, false}' "$TMP/rebar.config"
  ! grep -q '{include_erts, true}' "$TMP/rebar.config"
}

@test "patch_include_erts inserts false when absent" {
  printf '{relx, [\n  {release, {kazoo, "4.4"}, []}\n]}.\n' > "$TMP/rebar.config"
  patch_include_erts "$TMP/rebar.config"
  grep -q '{include_erts, false}' "$TMP/rebar.config"
}

@test "patch_erts_app_load_types starts the seven ERTS apps" {
  printf '%s\n' '{crypto, none}' '{ssl, none}' '{public_key, none}' '{asn1, none}' \
    '{compiler, none}' '{runtime_tools, none}' '{syntax_tools, none}' > "$TMP/rebar.config"
  patch_erts_app_load_types "$TMP/rebar.config"
  ! grep -q 'none' "$TMP/rebar.config"
  [ "$(grep -c . "$TMP/rebar.config")" -eq 7 ]
}

@test "patch_erts_app_load_types leaves os_mon as none" {
  printf '%s\n' '{os_mon, none}' '{crypto, none}' > "$TMP/rebar.config"
  patch_erts_app_load_types "$TMP/rebar.config"
  grep -q '{os_mon, none}' "$TMP/rebar.config"
  grep -qx 'crypto' "$TMP/rebar.config"
}

@test "patch_erts_app_load_types leaves kazoo kapps as none" {
  printf '%s\n' '{callflow, none}' '{crossbar, none}' '{pusher, none}' '{jonny5, none}' \
    '{ecallmgr, none}' > "$TMP/rebar.config"
  patch_erts_app_load_types "$TMP/rebar.config"
  [ "$(grep -c 'none' "$TMP/rebar.config")" -eq 5 ]
}

@test "patch_erts_app_load_types tolerates whitespace variants" {
  printf '%s\n' '{crypto,none}' '{ssl,   none}' > "$TMP/rebar.config"
  patch_erts_app_load_types "$TMP/rebar.config"
  ! grep -q 'none' "$TMP/rebar.config"
}

@test "synth_version produces base~branch.date.sha shape" {
  run synth_version 4.4 20260722 deadbeef
  [ "$output" = "4.4.0~4.4.20260722.deadbeef" ]
}

@test "make_ecallmgr_rel sets kazoo_media to load type none" {
  printf '%s\n' '{release,{"kazoo","0.0.0"},' '  [{kernel,"9.2.4.11"},' \
    '   {kazoo_media,"0.0.0+build.1.ref5555162"},' '   {kazoo,"0.0.0"}]}.' > "$TMP/kazoo.rel"
  make_ecallmgr_rel "$TMP/kazoo.rel" "$TMP/kazoo_ecallmgr.rel"
  grep -qF '{kazoo_media,"0.0.0+build.1.ref5555162",none}' "$TMP/kazoo_ecallmgr.rel"
}

@test "make_ecallmgr_rel leaves every other entry alone" {
  printf '%s\n' '{kernel,"9.2.4.11"},' '{kazoo_media,"1"},' '{kazoo,"0.0.0"},' \
    '{callflow,"1",none}' > "$TMP/kazoo.rel"
  make_ecallmgr_rel "$TMP/kazoo.rel" "$TMP/kazoo_ecallmgr.rel"
  diff <(grep -v kazoo_media "$TMP/kazoo.rel") <(grep -v kazoo_media "$TMP/kazoo_ecallmgr.rel")
}

@test "make_ecallmgr_rel dies when kazoo_media is absent" {
  printf '%s\n' '{kernel,"9.2.4.11"},' '{kazoo,"0.0.0"}' > "$TMP/kazoo.rel"
  run make_ecallmgr_rel "$TMP/kazoo.rel" "$TMP/kazoo_ecallmgr.rel"
  [ "$status" -eq 2 ]
}

@test "make_ecallmgr_rel dies when kazoo_media already has a load type" {
  printf '%s\n' '{kazoo_media,"1",load}' > "$TMP/kazoo.rel"
  run make_ecallmgr_rel "$TMP/kazoo.rel" "$TMP/kazoo_ecallmgr.rel"
  [ "$status" -eq 2 ]
}
