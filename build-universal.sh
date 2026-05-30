#!/usr/bin/env bash
set -euo pipefail

AOSP_TAG="${AOSP_TAG:-android-4.4_r1}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
WORK_DIR="${WORK_DIR:-}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$REPO_ROOT/dist"
fi

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d -t vivo-fastboot-build-XXXXXX)"
fi

if [[ "$KEEP_WORKDIR" -eq 0 ]]; then
  trap 'rm -rf "$WORK_DIR"' EXIT
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run_with_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "This script needs root privileges for dependency installation." >&2
    echo "Re-run as root or install dependencies manually and set SKIP_DEPS=1." >&2
    exit 1
  fi
}

install_deps() {
  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    run_with_sudo apt-get update
    run_with_sudo apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl tar xz-utils musl-tools linux-libc-dev
  elif command -v dnf >/dev/null 2>&1; then
    run_with_sudo dnf install -y \
      gcc gcc-c++ make ca-certificates curl tar xz \
      musl-gcc musl-devel kernel-headers
  elif command -v yum >/dev/null 2>&1; then
    run_with_sudo yum install -y \
      gcc gcc-c++ make ca-certificates curl tar xz \
      musl-gcc musl-devel kernel-headers
  elif command -v pacman >/dev/null 2>&1; then
    run_with_sudo pacman -Syu --needed --noconfirm \
      base-devel ca-certificates curl tar xz musl linux-headers
  elif command -v zypper >/dev/null 2>&1; then
    run_with_sudo zypper --non-interactive install \
      gcc gcc-c++ make ca-certificates curl tar xz \
      musl musl-devel kernel-devel
  elif command -v apk >/dev/null 2>&1; then
    run_with_sudo apk add --no-cache \
      build-base ca-certificates curl tar xz musl-dev linux-headers
  else
    echo "Unsupported distro: no known package manager found." >&2
    echo "Install dependencies manually and re-run with SKIP_DEPS=1." >&2
    exit 1
  fi
}

fetch_repo() {
  local name="$1"
  local dest="$2"
  shift 2
  local tarball="$WORK_DIR/${name}.tar.gz"
  local url
  local strip_flag=()
  local roots
  local root_count
  local has_root_files=0

  rm -rf "$dest"
  mkdir -p "$dest"

  for url in "$@"; do
    if curl -fsSL "$url" -o "$tarball"; then
      if tar -tzf "$tarball" | grep -qv '/'; then
        has_root_files=1
      fi
      if [[ "$has_root_files" -eq 0 ]]; then
        roots="$(tar -tzf "$tarball" | awk -F/ '{ print $1 }' | sort -u)"
        root_count="$(printf '%s\n' "$roots" | wc -l | tr -d ' ')"
      else
        root_count=0
      fi
      if [[ "$root_count" -eq 1 ]]; then
        strip_flag=(--strip-components=1)
      else
        strip_flag=()
      fi
      tar -xzf "$tarball" -C "$dest" "${strip_flag[@]}"
      return 0
    fi
  done

  echo "Failed to download $name from all sources." >&2
  return 1
}

prepare_kernel_headers() {
  local dest="$1"
  mkdir -p "$dest"
  if [[ -d /usr/include/linux ]]; then
    cp -a /usr/include/linux "$dest/"
  else
    echo "Missing /usr/include/linux; install kernel headers." >&2
    exit 1
  fi

  if [[ -d /usr/include/asm ]]; then
    cp -a /usr/include/asm "$dest/"
  elif [[ -d /usr/include/$(uname -m)-linux-gnu/asm ]]; then
    cp -a "/usr/include/$(uname -m)-linux-gnu/asm" "$dest/"
  elif [[ -d /usr/include/x86_64-linux-gnu/asm ]]; then
    cp -a /usr/include/x86_64-linux-gnu/asm "$dest/"
  else
    echo "Missing asm headers; install kernel headers." >&2
    exit 1
  fi

  if [[ -d /usr/include/asm-generic ]]; then
    cp -a /usr/include/asm-generic "$dest/"
  elif [[ -d /usr/include/$(uname -m)-linux-gnu/asm-generic ]]; then
    cp -a "/usr/include/$(uname -m)-linux-gnu/asm-generic" "$dest/"
  elif [[ -d /usr/include/x86_64-linux-gnu/asm-generic ]]; then
    cp -a /usr/include/x86_64-linux-gnu/asm-generic "$dest/"
  else
    echo "Missing asm-generic headers; install kernel headers." >&2
    exit 1
  fi
}

patch_libselinux() {
  local file="$AOSP_ROOT/external/libselinux/src/procattr.c"
  if [[ -f "$file" ]] && grep -q "static pid_t gettid" "$file"; then
    sed -i \
      -e 's/static pid_t gettid/static pid_t selinux_gettid/' \
      -e 's/\bgettid(/selinux_gettid(/g' \
      "$file"
  elif [[ -f "$file" ]] && grep -q "selinux_gettid" "$file"; then
    return 0
  fi
}

install_deps
require_cmd curl
require_cmd tar
require_cmd make

AOSP_ROOT="$WORK_DIR/aosp"
mkdir -p "$AOSP_ROOT"

fetch_repo "system-core" "$AOSP_ROOT/system/core" \
  "https://android.googlesource.com/platform/system/core/+archive/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror/platform_system_core/archive/refs/tags/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror-neo/platform_system_core/archive/refs/tags/${AOSP_TAG}.tar.gz"
fetch_repo "system-extras" "$AOSP_ROOT/system/extras" \
  "https://android.googlesource.com/platform/system/extras/+archive/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror/platform_system_extras/archive/refs/tags/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror-neo/platform_system_extras/archive/refs/tags/${AOSP_TAG}.tar.gz"
fetch_repo "external-libselinux" "$AOSP_ROOT/external/libselinux" \
  "https://android.googlesource.com/platform/external/libselinux/+archive/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror/platform_external_libselinux/archive/refs/tags/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror-neo/platform_external_libselinux/archive/refs/tags/${AOSP_TAG}.tar.gz"
fetch_repo "external-zlib" "$AOSP_ROOT/external/zlib" \
  "https://android.googlesource.com/platform/external/zlib/+archive/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror/platform_external_zlib/archive/refs/tags/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror-neo/platform_external_zlib/archive/refs/tags/${AOSP_TAG}.tar.gz"
fetch_repo "external-openssl" "$AOSP_ROOT/external/openssl" \
  "https://android.googlesource.com/platform/external/openssl/+archive/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror/platform_external_openssl/archive/refs/tags/${AOSP_TAG}.tar.gz" \
  "https://github.com/aosp-mirror-neo/platform_external_openssl/archive/refs/tags/${AOSP_TAG}.tar.gz"

rm -rf "$AOSP_ROOT/system/core/fastboot"
cp -a "$REPO_ROOT" "$AOSP_ROOT/system/core/fastboot"

KERNEL_HEADERS="$AOSP_ROOT/kernel-headers"
prepare_kernel_headers "$KERNEL_HEADERS"
patch_libselinux

SHIM_DIR="$AOSP_ROOT/system/core/fastboot/compat/sys"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/cdefs.h" <<'EOF'
#ifndef _SYS_CDEFS_H
#define _SYS_CDEFS_H

#ifdef __cplusplus
#define __BEGIN_DECLS extern "C" {
#define __END_DECLS }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif

#endif
EOF

CC_BIN="${CC:-musl-gcc}"
LD_BIN="${LD:-musl-gcc}"
require_cmd "$CC_BIN"

make -C "$AOSP_ROOT/system/core/fastboot" \
  CC="$CC_BIN" LD="$LD_BIN" \
  CFLAGS="-pthread -fcommon -I\"$KERNEL_HEADERS\" -I\"$AOSP_ROOT/system/core/fastboot/compat\"" \
  LDFLAGS="-static -s -pthread"

mkdir -p "$OUTPUT_DIR"
cp "$AOSP_ROOT/system/core/fastboot/fastboot" "$OUTPUT_DIR/fastboot"

if command -v file >/dev/null 2>&1; then
  file "$OUTPUT_DIR/fastboot" || true
fi
if command -v ldd >/dev/null 2>&1; then
  ldd "$OUTPUT_DIR/fastboot" || true
fi

echo "Build complete: $OUTPUT_DIR/fastboot"
