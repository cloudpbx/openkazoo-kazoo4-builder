setup() { load '../../scripts/lib.sh'; }

@test "arch_normalize maps x86_64 to amd64" {
  run arch_normalize x86_64
  [ "$status" -eq 0 ]; [ "$output" = "amd64" ]
}
@test "arch_normalize maps aarch64 to arm64" {
  run arch_normalize aarch64
  [ "$output" = "arm64" ]
}
@test "arch_normalize passes through amd64/arm64" {
  run arch_normalize amd64; [ "$output" = "amd64" ]
  run arch_normalize arm64; [ "$output" = "arm64" ]
}
@test "arch_normalize rejects unknown arch" {
  run arch_normalize sparc; [ "$status" -ne 0 ]
}
