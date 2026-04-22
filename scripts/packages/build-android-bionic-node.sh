#!/usr/bin/env bash
# Build Node.js linked against Android Bionic (aarch64).
#
# CI:    bash scripts/packages/build-android-bionic-node.sh
# Local: BUILD_WORK_DIR=/tmp/node-bionic-build \
#        bash scripts/packages/build-android-bionic-node.sh \
#             manifests/android-bionic-node.env /tmp/node-bionic-dist
#
# Requirements (automatically satisfied on GitHub Actions ubuntu-22.04):
#   - ANDROID_NDK_LATEST_HOME pointing to a valid NDK (r25+)
#   - build-essential, git, python3, ninja-build
#
# Output:
#   dist/android-bionic-node/node-android-arm64-bionic-<version>.tar.gz
#     ├── bin/node         (aarch64 ELF, linked against Bionic)
#     ├── lib/node_modules/npm/   (npm and npx JS scripts)
#     └── MANIFEST.txt

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${script_dir}/../lib/common.sh"
# shellcheck source=../lib/ndk.sh
source "${script_dir}/../lib/ndk.sh"

repo_dir="$(repo_root)"
manifest_path="${1:-${repo_dir}/manifests/android-bionic-node.env}"
output_dir="${2:-${repo_dir}/dist/android-bionic-node}"

load_manifest "$manifest_path"

require_cmd make
require_cmd python3
require_cmd git

artifact_name="${ARTIFACT_NAME:-node-android-arm64-bionic}"
work_dir="${BUILD_WORK_DIR:-${repo_dir}/build/android-bionic-node}"
src_dir="${work_dir}/node-${NODE_VERSION}"

ndk_setup_env "${ANDROID_API:-21}" "aarch64"

rm -rf "$work_dir" "$output_dir"
ensure_dir "$work_dir"
ensure_dir "$output_dir"

# -----------------------------------------------------------------
# 1. Download Node.js source
# -----------------------------------------------------------------
log_step "Downloading Node.js ${NODE_VERSION} source"
download_file \
  "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}.tar.xz" \
  "${work_dir}/node-${NODE_VERSION}.tar.xz"
extract_archive "${work_dir}/node-${NODE_VERSION}.tar.xz" "$work_dir"
[[ -d "$src_dir" ]] || fail "Expected source directory not found: ${src_dir}"

# -----------------------------------------------------------------
# 2. Install build-time host dependencies (no-op if already present)
# -----------------------------------------------------------------
log_step "Ensuring host build tools are available"
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get install -y --no-install-recommends \
    build-essential \
    ninja-build \
    python3 \
    g++ \
    > /dev/null 2>&1 || true
fi

# -----------------------------------------------------------------
# 3. Configure
#
#   --dest-os=android          tells GYP/V8 the target OS is Android
#   --dest-cpu=arm64           target CPU architecture
#   --cross-compiling          enables split host/target compiler paths
#   --android-ndk-path         required by node.gyp since Node.js v18;
#                              points to the NDK root directory.
#   --openssl-no-asm           disable OpenSSL hand-written assembler
#                              to keep the build simpler; not needed for
#                              correctness on aarch64 but simplifies NDK
#                              integration for initial builds.
#   Note: --without-snapshot was removed in Node.js v24. The snapshot
#         is now always built; Node.js uses the host mksnapshot binary
#         automatically when cross-compiling.
#   CC_host / CXX_host         native compilers for host-only tools
#                              (mksnapshot, node_js2c, etc.)
# -----------------------------------------------------------------
log_step "Configuring Node.js for android/arm64"
pushd "$src_dir" >/dev/null

CC_HOST="$(command -v gcc)"
CXX_HOST="$(command -v g++)"

./configure \
  --dest-os=android \
  --dest-cpu=arm64 \
  --cross-compiling \
  --android-ndk-path="${ANDROID_NDK_ROOT}" \
  --openssl-no-asm \
  CC_host="${CC_HOST}" \
  CXX_host="${CXX_HOST}"

# -----------------------------------------------------------------
# 4. Compile
# -----------------------------------------------------------------
log_step "Compiling Node.js (this takes 45–90 minutes on a 2-core runner)"
make -j"$(nproc)" node

# -----------------------------------------------------------------
# 5. Verify and strip
# -----------------------------------------------------------------
ndk_check_binary "./node"
"$STRIP" --strip-unneeded ./node

# -----------------------------------------------------------------
# 6. Package
#   Include node binary + npm/npx JS scripts so npm works once
#   node is available on the Android device.
# -----------------------------------------------------------------
log_step "Packaging artifacts"
popd >/dev/null

bundle="${output_dir}/bundle"
mkdir -p "${bundle}/bin"
cp "${src_dir}/node" "${bundle}/bin/node"

# Carry npm and npx wrappers (pure JS, they just need `node` in PATH)
if [[ -d "${src_dir}/deps/npm" ]]; then
  mkdir -p "${bundle}/lib/node_modules/npm"
  cp -a "${src_dir}/deps/npm/." "${bundle}/lib/node_modules/npm/"

  # Thin shell wrapper so PATH resolution works on Android
  for cmd in npm npx; do
    if [[ -f "${bundle}/lib/node_modules/npm/bin/${cmd}-cli.js" ]]; then
      program_file="${bundle}/lib/node_modules/npm/bin/${cmd}-cli.js"
    else
      program_file="${bundle}/lib/node_modules/npm/bin/${cmd}"
    fi
    cat > "${bundle}/bin/${cmd}" <<EOF
#!/bin/sh
exec "\$(dirname "\$0")/node" "${program_file}" "\$@"
EOF
    chmod +x "${bundle}/bin/${cmd}"
  done
fi

cat > "${output_dir}/MANIFEST.txt" <<EOF
ARTIFACT_NAME=${artifact_name}
NODE_VERSION=${NODE_VERSION}
ANDROID_API=${ANDROID_API}
ANDROID_TARGET_API=${ANDROID_TARGET_API}
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

archive_path="${output_dir}/${artifact_name}-${NODE_VERSION}.tar.gz"
tar -czf "$archive_path" -C "$output_dir" bundle MANIFEST.txt

log_step "Node.js aarch64-linux-android artifact written to ${archive_path}"
log_step "Deploy: push ${bundle}/bin/* to /data/local/tmp/bin on the device"
