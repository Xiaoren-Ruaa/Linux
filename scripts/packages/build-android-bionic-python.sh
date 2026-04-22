#!/usr/bin/env bash
# Build CPython linked against Android Bionic (aarch64).
#
# CPython 3.13+ has first-class Android cross-compilation support.
# The --host=aarch64-linux-android<API> triplet is officially recognised.
#
# CI:    bash scripts/packages/build-android-bionic-python.sh
# Local: BUILD_WORK_DIR=/tmp/py-bionic-build \
#        bash scripts/packages/build-android-bionic-python.sh \
#             manifests/android-bionic-python.env /tmp/py-bionic-dist
#
# Requirements (automatically satisfied on GitHub Actions ubuntu-22.04):
#   - ANDROID_NDK_LATEST_HOME pointing to a valid NDK (r25+)
#   - python3 (>=3.11, used as host build Python)
#   - build-essential, libssl-dev, libffi-dev, zlib1g-dev, pkg-config
#
# Output:
#   dist/android-bionic-python/python-android-arm64-bionic-<version>.tar.gz
#     └── python/
#           bin/python3
#           lib/python3.x/        (standard library, no tests)
#           MANIFEST.txt

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${script_dir}/../lib/common.sh"
# shellcheck source=../lib/ndk.sh
source "${script_dir}/../lib/ndk.sh"

repo_dir="$(repo_root)"
manifest_path="${1:-${repo_dir}/manifests/android-bionic-python.env}"
output_dir="${2:-${repo_dir}/dist/android-bionic-python}"

load_manifest "$manifest_path"

require_cmd python3
require_cmd make

artifact_name="${ARTIFACT_NAME:-python-android-arm64-bionic}"
work_dir="${BUILD_WORK_DIR:-${repo_dir}/build/android-bionic-python}"
src_archive="${work_dir}/Python-${PYTHON_VERSION}.tar.xz"
native_src="${work_dir}/Python-${PYTHON_VERSION}-native"
cross_src="${work_dir}/Python-${PYTHON_VERSION}-cross"
native_prefix="${work_dir}/native"
xz_version="${XZ_VERSION:-5.6.4}"
xz_archive="${work_dir}/xz-${xz_version}.tar.xz"
xz_src="${work_dir}/xz-${xz_version}"
target_deps_prefix="${work_dir}/target-deps"

ndk_setup_env "${ANDROID_API:-21}" "aarch64"

rm -rf "$work_dir" "$output_dir"
ensure_dir "$work_dir"
ensure_dir "$output_dir"

# ------------------------------------------------------------------
# 1. Host build dependencies
# ------------------------------------------------------------------
log_step "Ensuring host build dependencies are present"
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libffi-dev \
    zlib1g-dev \
    pkg-config \
    > /dev/null 2>&1 || true
fi

# ------------------------------------------------------------------
# 2. Download CPython source (shared between native and cross trees)
# ------------------------------------------------------------------
log_step "Downloading CPython ${PYTHON_VERSION}"
download_file \
  "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
  "$src_archive"

extract_archive "$src_archive" "$work_dir"
mv "${work_dir}/Python-${PYTHON_VERSION}" "$native_src"
# Cross-build gets a fresh copy so the two configure passes don't
# stomp on each other's generated files.
cp -a "$native_src" "$cross_src"

# ------------------------------------------------------------------
# 3. Build native (host) Python
#    Used only to satisfy --with-build-python during the cross-build.
#    We temporarily unset the Android toolchain variables so the host
#    compiler is used.
# ------------------------------------------------------------------
log_step "Building native (host) Python ${PYTHON_VERSION}"

(
  # Restore host compilers inside this sub-shell
  unset CC CXX AR AS LD NM RANLIB READELF STRIP OBJCOPY SYSROOT
  pushd "$native_src" >/dev/null

  ./configure \
    --prefix="$native_prefix" \
    --without-ensurepip \
    --quiet

  make -j"$(nproc)" --no-print-directory
  make install --no-print-directory
  popd >/dev/null
)

native_python="${native_prefix}/bin/python3"
[[ -f "$native_python" ]] || fail "Native Python not built: $native_python"

# ------------------------------------------------------------------
# 4. Build target-side liblzma
#
#   The runner has host liblzma development files installed, so
#   CPython's configure would otherwise pick up the host pkg-config
#   result and later fail when the Android compiler cannot find the
#   target headers. Build a target-side static PIC liblzma and point
#   LIBLZMA_CFLAGS / LIBLZMA_LIBS at it explicitly.
# ------------------------------------------------------------------
log_step "Building liblzma ${xz_version} for aarch64-linux-android${ANDROID_API}"

download_file \
  "https://tukaani.org/xz/xz-${xz_version}.tar.xz" \
  "$xz_archive"
extract_archive "$xz_archive" "$work_dir"
[[ -d "$xz_src" ]] || fail "Expected xz source directory not found: ${xz_src}"

(
  pushd "$xz_src" >/dev/null

  CFLAGS="${CFLAGS:-} -fPIC" \
  ./configure \
    --host="aarch64-linux-android${ANDROID_API}" \
    --build="x86_64-linux-gnu" \
    --prefix="$target_deps_prefix" \
    --disable-shared \
    --enable-static

  make -j"$(nproc)" --no-print-directory
  make install --no-print-directory
  popd >/dev/null
)

export LIBLZMA_CFLAGS="-I${target_deps_prefix}/include"
export LIBLZMA_LIBS="-L${target_deps_prefix}/lib -llzma"

# ------------------------------------------------------------------
# 5. Cross-compile CPython for aarch64-linux-android<API>
#
#   CPython 3.13 treats the <API>-suffixed host triplet as Android and
#   adjusts build flags accordingly (Bionic libc linkage, no fork,
#   ANDROID_PRIVATE_LIBS, etc.).
#
#   Key configure knobs:
#     --host=aarch64-linux-android21
#       Recognised by CPython 3.13 as an Android target; sets
#       _PYTHON_HOST_PLATFORM=android-arm64-21 and switches to
#       Bionic-compatible syscall assumptions.
#     --with-build-python
#       The native Python used to run pgen, freeze_importlib, etc.
#     --disable-test-modules
#       Skip building _testcapi, _testinternalcapi and friends.
#       These are not needed at runtime and add build time.
#     LIBLZMA_CFLAGS / LIBLZMA_LIBS
#       Force CPython's _lzma probe to use the target-side liblzma we
#       just built instead of the runner's host pkg-config result.
#     ac_cv_file__dev_ptmx / ac_cv_file__dev_ptc
#       Bionic does not provide these devices; suppress the autoconf
#       checks that would otherwise fail at configure time.
# ------------------------------------------------------------------
log_step "Cross-compiling CPython ${PYTHON_VERSION} → aarch64-linux-android${ANDROID_API}"
pushd "$cross_src" >/dev/null

INSTALL_PREFIX="/data/local/python"

./configure \
  --host="aarch64-linux-android${ANDROID_API}" \
  --build="x86_64-linux-gnu" \
  --with-build-python="$native_python" \
  --prefix="$INSTALL_PREFIX" \
  --without-ensurepip \
  --disable-test-modules \
  --disable-ipv6 \
  ac_cv_file__dev_ptmx=no \
  ac_cv_file__dev_ptc=no

make -j"$(nproc)"

popd >/dev/null

# ------------------------------------------------------------------
# 6. Verify and strip
# ------------------------------------------------------------------
python_bin="${cross_src}/python"
ndk_check_binary "$python_bin"
"$STRIP" --strip-unneeded "$python_bin"

# ------------------------------------------------------------------
# 7. Collect standard library
#    We install to a staging dir, then repack without the large test/
#    trees and other optional cruft.
# ------------------------------------------------------------------
log_step "Collecting standard library"

staging="${work_dir}/staging"
(
  pushd "$cross_src" >/dev/null
  # installdir key: DESTDIR overrides prefix for staging
  make install DESTDIR="$staging" >/dev/null
  popd >/dev/null
)

bundle="${output_dir}/python"
python_minor="$(echo "$PYTHON_VERSION" | cut -d. -f1-2)"  # e.g. 3.13

ensure_dir "${bundle}/bin"
ensure_dir "${bundle}/lib"

cp "${python_bin}" "${bundle}/bin/python3"
ln -sf python3 "${bundle}/bin/python"

# Carry standard library; skip test packages to save space
lib_src="${staging}${INSTALL_PREFIX}/lib/python${python_minor}"
if [[ -d "$lib_src" ]]; then
  cp -a "$lib_src" "${bundle}/lib/"
  # Drop test directories (~50 MB)
  find "${bundle}/lib" \
    -type d \( -name test -o -name tests -o -name __pycache__ \) \
    -exec rm -rf {} + 2>/dev/null || true
fi

cat > "${bundle}/MANIFEST.txt" <<EOF
ARTIFACT_NAME=${artifact_name}
PYTHON_VERSION=${PYTHON_VERSION}
ANDROID_API=${ANDROID_API}
ANDROID_TARGET_API=${ANDROID_TARGET_API}
INSTALL_PREFIX=${INSTALL_PREFIX}
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ------------------------------------------------------------------
# 8. Package
# ------------------------------------------------------------------
archive_path="${output_dir}/${artifact_name}-${PYTHON_VERSION}.tar.gz"
tar -czf "$archive_path" -C "$output_dir" python

log_step "Python aarch64-linux-android artifact written to ${archive_path}"
log_step "Deploy: push the 'python/' tree to ${INSTALL_PREFIX} on the device"
log_step "Usage on device: \$INSTALL_PREFIX/bin/python3 -c 'import sys; print(sys.version)'"
