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

@test "synth_version produces base~branch.date.sha shape" {
  run synth_version 4.4 20260722 deadbeef
  [ "$output" = "4.4.0~4.4.20260722.deadbeef" ]
}
