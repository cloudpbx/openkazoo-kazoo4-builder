#!/usr/bin/env bash
# lib.sh — shared helpers, sourced by every build/sign/publish script.

die() { echo "ERROR: $*" >&2; exit 2; }

# arch_normalize <raw> -> amd64|arm64 (accepts x86_64/aarch64/amd64/arm64)
arch_normalize() {
  case "$1" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "unknown arch: $1" >&2; return 1 ;;
  esac
}

# repo_root -> absolute path to the checkout (scripts/..)
repo_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

# write_deb_control <dir> <pkg> <version> <arch> <desc> [depends]
# Emits a minimal DEBIAN/control (mirrors the playbook's hand-written control).
write_deb_control() {
  local dir="$1" pkg="$2" ver="$3" arch="$4" desc="$5" depends="${6:-}"
  mkdir -p "$dir/DEBIAN"
  {
    echo "Package: $pkg"
    echo "Version: $ver"
    echo "Architecture: $arch"
    echo "Maintainer: openkazoo build <build@cloudpbx.example>"
    [ -n "$depends" ] && echo "Depends: $depends"
    echo "Description: $desc"
  } > "$dir/DEBIAN/control"
}
