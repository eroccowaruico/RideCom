#!/usr/bin/env bash
set -euo pipefail

# Builds WebRTC.xcframework from the official WebRTC source tree without
# checking Chromium/WebRTC sources into this repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_PARENT="$(cd "${REPOSITORY_ROOT}/.." && pwd)"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-${REPOSITORY_PARENT}/depot_tools}"
# shellcheck source=scripts/BuildWebRTC/webrtc-build-root.sh
source "${SCRIPT_DIR}/webrtc-build-root.sh"
WEBRTC_BRANCH="${WEBRTC_BRANCH:-}"
DEBUG="${DEBUG:-false}"
IOS="${IOS:-true}"
MACOS="${MACOS:-true}"
ASSEMBLE_ONLY="${ASSEMBLE_ONLY:-false}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-27.0}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-27.0}"

if [[ "${IOS}" != "true" || "${MACOS}" != "true" ]]; then
  echo "The RTC package requires all iOS, iOS Simulator and macOS slices." >&2
  exit 2
fi

if [[ -z "${WEBRTC_BRANCH}" ]]; then
  WEBRTC_BRANCH="$("${SCRIPT_DIR}/resolve-webrtc-branch.sh")"
fi

if [[ ! -x "${DEPOT_TOOLS_DIR}/fetch" || ! -x "${DEPOT_TOOLS_DIR}/gclient" ]]; then
  echo "depot_tools was not found at: ${DEPOT_TOOLS_DIR}" >&2
  echo "Set DEPOT_TOOLS_DIR to the directory containing fetch and gclient." >&2
  exit 1
fi

case ":${PATH}:" in
  *":${DEPOT_TOOLS_DIR}:"*) ;;
  *) export PATH="${DEPOT_TOOLS_DIR}:${PATH}" ;;
esac

echo "Building WebRTC from ${WEBRTC_BRANCH}"
echo "Build root: ${WEBRTC_BUILD_ROOT}"
echo "Platforms: IOS=${IOS}, MACOS=${MACOS}"
echo "Assemble only: ${ASSEMBLE_ONLY}"

mkdir -p "${WEBRTC_BUILD_ROOT}"
cd "${WEBRTC_BUILD_ROOT}"

if [[ "${ASSEMBLE_ONLY}" != "true" && ! -d src ]]; then
  fetch --nohooks webrtc_ios
fi

if [[ ! -d src ]]; then
  echo "WebRTC source checkout was not found: ${WEBRTC_BUILD_ROOT}/src" >&2
  echo "Run without ASSEMBLE_ONLY=true first." >&2
  exit 1
fi

cd src

if [[ "${ASSEMBLE_ONLY}" != "true" ]]; then
  checkout_status="$(git status --porcelain --untracked-files=no)"
  if [[ -n "${checkout_status}" ]]; then
    echo "WebRTC source has local changes; use a clean checkout." >&2
    exit 1
  fi
  # Resolve the requested revision at the official repository, not a local ref.
  upstream_ref="${WEBRTC_BRANCH}"
  case "${upstream_ref}" in branch-heads/*) upstream_ref="refs/${upstream_ref}" ;; esac
  git fetch --no-tags https://webrtc.googlesource.com/src "${upstream_ref}"
  upstream_revision="$(git rev-parse --verify 'FETCH_HEAD^{commit}')"
  git checkout --detach "${upstream_revision}"
  cd ..
  gclient sync --with_branch_heads --with_tags --revision "src@${upstream_revision}"
  cd src
  verify_vendor_sources() {
    local current_revision
    current_revision="$(git rev-parse HEAD)" || return 1
    [[ "${current_revision}" == "${upstream_revision}" ]] &&
      gclient recurse --scm=git -- git diff --quiet HEAD --
  }
  verify_vendor_sources
  depot_tools_revision="$(git -C "${DEPOT_TOOLS_DIR}" rev-parse HEAD)"
  export DEPOT_TOOLS_UPDATE=0
else
  echo "Reusing prepared GN directories for inspection. Ninja may build missing inputs."
fi

OUTPUT_DIR="${PWD}/out"
XCFRAMEWORK_DIR="${OUTPUT_DIR}/WebRTC.xcframework"
# Realtime audio uses DataChannel; no RTP encoders or serialized event log are needed.
COMMON_GN_ARGS="treat_warnings_as_errors=false is_debug=${DEBUG} rtc_libvpx_build_vp9=false is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=true use_lld=true rtc_ios_use_opengl_rendering=false rtc_use_h264=false rtc_use_h265=false rtc_enable_protobuf=false"

prepare_slice() {
  local gen_dir="$1"
  local platform_args="$2"
  gn gen "${gen_dir}" --args="${COMMON_GN_ARGS} ${platform_args}"
  gn args --list "${gen_dir}" > "${gen_dir}/gn-args.txt"
}

prepare_ios() {
  local arch="$1"
  local environment="$2"
  local enable_dsyms=false
  [[ "${environment}" != "device" ]] || enable_dsyms=true
  prepare_slice "${OUTPUT_DIR}/ios-${arch}-${environment}" \
    "enable_dsyms=${enable_dsyms} target_cpu=\"${arch}\" target_os=\"ios\" target_environment=\"${environment}\" ios_deployment_target=\"${IOS_DEPLOYMENT_TARGET}\" ios_enable_code_signing=false"
}

prepare_macos() {
  local arch="$1"
  prepare_slice "${OUTPUT_DIR}/macos-${arch}" \
    "enable_dsyms=false target_cpu=\"${arch}\" target_os=\"mac\" mac_deployment_target=\"${MACOS_DEPLOYMENT_TARGET}\""
}

if [[ "${ASSEMBLE_ONLY}" != "true" ]]; then
  prepare_ios x64 simulator
  prepare_ios arm64 simulator
  prepare_ios arm64 device
  prepare_macos x64
  prepare_macos arm64
fi

# Check the new framework before touching the previous outputs. The import step
# independently checks the copied ZIP and exchanges the package artifact and
# metadata together.
staging="$(mktemp -d "${OUTPUT_DIR}/.WebRTC.XXXXXXXX")"
trap 'rm -rf -- "${staging}"' EXIT
python3 "${SCRIPT_DIR}/assemble_webrtc_modular_xcframework.py" "${PWD}" "${OUTPUT_DIR}" "${staging}/WebRTC.xcframework"

artifact_stem="WebRTC-${WEBRTC_BRANCH//\//-}"
if [[ "${ASSEMBLE_ONLY}" == "true" ]]; then
  artifact_stem+=".inspection"
fi
artifact_zip="${artifact_stem}.xcframework.zip"
(
  cd "${staging}"
  zip --symlinks -q -r "${artifact_zip}" WebRTC.xcframework
)
if [[ "${ASSEMBLE_ONLY}" != "true" ]]; then
  verify_vendor_sources
  built_tools_revision="$(git -C "${DEPOT_TOOLS_DIR}" rev-parse HEAD)"
  if [[ "${built_tools_revision}" != "${depot_tools_revision}" ]]; then
    echo "depot_tools changed during the build." >&2
    exit 1
  fi
  python3 "${SCRIPT_DIR}/webrtc_provenance.py" "${staging}/${artifact_zip}" \
    "${upstream_revision}" "${depot_tools_revision}" iphoneos iphonesimulator macosx --gn-output "${OUTPUT_DIR}"
fi

if [[ -e "${XCFRAMEWORK_DIR}" || -L "${XCFRAMEWORK_DIR}" ]]; then
  mv -- "${XCFRAMEWORK_DIR}" "${staging}/previous-WebRTC.xcframework"
fi
mv -- "${staging}/WebRTC.xcframework" "${XCFRAMEWORK_DIR}"
if [[ "${ASSEMBLE_ONLY}" != "true" ]]; then
  mv -f -- "${staging}/${artifact_stem}.xcframework.provenance.json" "${OUTPUT_DIR}/"
fi
mv -f -- "${staging}/${artifact_zip}" "${OUTPUT_DIR}/"
shasum -a 256 "${OUTPUT_DIR}/${artifact_zip}"
echo "Built: ${XCFRAMEWORK_DIR}"
