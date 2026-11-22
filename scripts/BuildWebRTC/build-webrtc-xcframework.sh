#!/usr/bin/env bash
set -euo pipefail

# Builds WebRTC.xcframework from the official WebRTC source tree without
# checking Chromium/WebRTC sources into this repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_PARENT="$(cd "${REPOSITORY_ROOT}/.." && pwd)"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-${REPOSITORY_PARENT}/depot_tools}"
WEBRTC_BUILD_ROOT="${WEBRTC_BUILD_ROOT:-${REPOSITORY_PARENT}/webrtc-build}"
WEBRTC_BRANCH="${WEBRTC_BRANCH:-}"
DEBUG="${DEBUG:-false}"
IOS="${IOS:-true}"
MACOS="${MACOS:-true}"
ASSEMBLE_ONLY="${ASSEMBLE_ONLY:-false}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-27.0}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-27.0}"

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
  echo "Skipping checkout, gclient sync, gn, and ninja. Existing build outputs will be assembled."
fi

OUTPUT_DIR="${PWD}/out"
XCFRAMEWORK_DIR="${OUTPUT_DIR}/WebRTC.xcframework"
# Upstream deprecation warnings from newer Apple SDKs remain visible in logs.
# Do not make vendor warnings fatal; compiler/linker errors still fail the build.
# RideCom uses DataChannel and does not use WebRTC's serialized event log.
COMMON_GN_ARGS="treat_warnings_as_errors=false is_debug=${DEBUG} rtc_libvpx_build_vp9=false is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=true use_lld=true rtc_ios_use_opengl_rendering=false rtc_use_h264=false rtc_use_h265=false rtc_enable_protobuf=false"
PLISTBUDDY_EXEC="/usr/libexec/PlistBuddy"

build_slice() {
  local gen_dir="$1"
  local target="$2"
  local platform_args="$3"
  gn gen "${gen_dir}" --args="${COMMON_GN_ARGS} ${platform_args}"
  gn args --list "${gen_dir}" > "${gen_dir}/gn-args.txt"
  ninja -C "${gen_dir}" "${target}"
}

build_ios() {
  local arch="$1"
  local environment="$2"
  # Device symbols must travel with the iOS binary for App Store uploads.
  local enable_dsyms=false
  [[ "${environment}" != "device" ]] || enable_dsyms=true
  build_slice "${OUTPUT_DIR}/ios-${arch}-${environment}" framework_objc \
    "enable_dsyms=${enable_dsyms} target_cpu=\"${arch}\" target_os=\"ios\" target_environment=\"${environment}\" ios_deployment_target=\"${IOS_DEPLOYMENT_TARGET}\" ios_enable_code_signing=false"
}

build_macos() {
  local arch="$1"
  build_slice "${OUTPUT_DIR}/macos-${arch}" mac_framework_objc \
    "enable_dsyms=false target_cpu=\"${arch}\" target_os=\"mac\" mac_deployment_target=\"${MACOS_DEPLOYMENT_TARGET}\""
}

plist_add_library() {
  local index="$1"
  local identifier="$2"
  local platform="$3"
  local platform_variant="${4:-}"
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries: dict" "${INFO_PLIST}"
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${index}:LibraryIdentifier string ${identifier}" "${INFO_PLIST}"
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${index}:LibraryPath string WebRTC.framework" "${INFO_PLIST}"
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${index}:SupportedArchitectures array" "${INFO_PLIST}"
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${index}:SupportedPlatform string ${platform}" "${INFO_PLIST}"
  if [[ -n "${platform_variant}" ]]; then
    "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${index}:SupportedPlatformVariant string ${platform_variant}" "${INFO_PLIST}"
  fi
}

plist_add_architecture() {
  local index="$1"
  local arch="$2"
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${index}:SupportedArchitectures: string ${arch}" "${INFO_PLIST}"
}

framework_headers_dir() {
  local framework_dir="$1"
  if [[ -d "${framework_dir}/Headers" ]]; then
    echo "${framework_dir}/Headers"
  else
    echo "${framework_dir}/Versions/A/Headers"
  fi
}

copy_missing_public_headers() {
  local source_framework="$1"
  local destination_framework="$2"
  local source_headers
  local destination_headers
  source_headers="$(framework_headers_dir "${source_framework}")"
  destination_headers="$(framework_headers_dir "${destination_framework}")"
  [[ -d "${source_headers}" && -d "${destination_headers}" ]] || return 0
  find "${source_headers}" -maxdepth 1 -type f -name '*.h' -print0 | while IFS= read -r -d '' header; do
    local header_name
    header_name="$(basename "${header}")"
    if [[ ! -f "${destination_headers}/${header_name}" ]]; then
      cp "${header}" "${destination_headers}/${header_name}"
    fi
  done
}


if [[ "${IOS}" == "true" && "${ASSEMBLE_ONLY}" != "true" ]]; then
  build_ios x64 simulator
  build_ios arm64 simulator
  build_ios arm64 device
fi

if [[ "${MACOS}" == "true" && "${ASSEMBLE_ONLY}" != "true" ]]; then
  build_macos x64
  build_macos arm64
fi

INFO_PLIST="${XCFRAMEWORK_DIR}/Info.plist"
rm -rf "${XCFRAMEWORK_DIR}"
mkdir -p "${XCFRAMEWORK_DIR}"
"${PLISTBUDDY_EXEC}" -c "Add :CFBundlePackageType string XFWK" "${INFO_PLIST}"
"${PLISTBUDDY_EXEC}" -c "Add :XCFrameworkFormatVersion string 1.0" "${INFO_PLIST}"
"${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries array" "${INFO_PLIST}"

library_count=0

if [[ "${IOS}" == "true" ]]; then
  ios_identifier="ios-arm64"
  simulator_identifier="ios-x86_64_arm64-simulator"
  mkdir "${XCFRAMEWORK_DIR}/${ios_identifier}" "${XCFRAMEWORK_DIR}/${simulator_identifier}"
  plist_add_library "${library_count}" "${ios_identifier}" ios
  plist_add_architecture "${library_count}" arm64
  "${PLISTBUDDY_EXEC}" -c "Add :AvailableLibraries:${library_count}:DebugSymbolsPath string dSYMs" "${INFO_PLIST}"
  device_dsym="${OUTPUT_DIR}/ios-arm64-device/WebRTC.dSYM"
  if [[ ! -f "${device_dsym}/Contents/Resources/DWARF/WebRTC" ]]; then
    echo "Missing iOS device dSYM: rebuild with enable_dsyms=true." >&2
    exit 1
  fi
  mkdir -p "${XCFRAMEWORK_DIR}/${ios_identifier}/dSYMs"
  cp -R "${device_dsym}" "${XCFRAMEWORK_DIR}/${ios_identifier}/dSYMs/WebRTC.framework.dSYM"
  library_count=$((library_count + 1))
  plist_add_library "${library_count}" "${simulator_identifier}" ios simulator
  plist_add_architecture "${library_count}" arm64
  plist_add_architecture "${library_count}" x86_64
  library_count=$((library_count + 1))
  cp -R "${OUTPUT_DIR}/ios-arm64-device/WebRTC.framework" "${XCFRAMEWORK_DIR}/${ios_identifier}"
  cp -R "${OUTPUT_DIR}/ios-x64-simulator/WebRTC.framework" "${XCFRAMEWORK_DIR}/${simulator_identifier}"
  lipo -create -output "${XCFRAMEWORK_DIR}/${ios_identifier}/WebRTC.framework/WebRTC" "${OUTPUT_DIR}/ios-arm64-device/WebRTC.framework/WebRTC"
  lipo -create -output "${XCFRAMEWORK_DIR}/${simulator_identifier}/WebRTC.framework/WebRTC" "${OUTPUT_DIR}/ios-x64-simulator/WebRTC.framework/WebRTC" "${OUTPUT_DIR}/ios-arm64-simulator/WebRTC.framework/WebRTC"
  xcrun codesign -s - "${XCFRAMEWORK_DIR}/${simulator_identifier}/WebRTC.framework/WebRTC"
fi

if [[ "${MACOS}" == "true" ]]; then
  macos_identifier="macos-x86_64_arm64"
  mkdir "${XCFRAMEWORK_DIR}/${macos_identifier}"
  plist_add_library "${library_count}" "${macos_identifier}" macos
  plist_add_architecture "${library_count}" x86_64
  plist_add_architecture "${library_count}" arm64
  library_count=$((library_count + 1))
  cp -RP "${OUTPUT_DIR}/macos-x64/WebRTC.framework" "${XCFRAMEWORK_DIR}/${macos_identifier}"
  if [[ -d "${OUTPUT_DIR}/macos-x64/gen/sdk/WebRTC.framework/Headers" ]]; then
    copy_missing_public_headers "${OUTPUT_DIR}/macos-x64/gen/sdk/WebRTC.framework" "${XCFRAMEWORK_DIR}/${macos_identifier}/WebRTC.framework"
  elif [[ -d "${OUTPUT_DIR}/ios-arm64-device/WebRTC.framework/Headers" ]]; then
    copy_missing_public_headers "${OUTPUT_DIR}/ios-arm64-device/WebRTC.framework" "${XCFRAMEWORK_DIR}/${macos_identifier}/WebRTC.framework"
  fi
  lipo -create -output "${XCFRAMEWORK_DIR}/${macos_identifier}/WebRTC.framework/Versions/A/WebRTC" "${OUTPUT_DIR}/macos-x64/WebRTC.framework/WebRTC" "${OUTPUT_DIR}/macos-arm64/WebRTC.framework/WebRTC"
fi

# Some upstream GN versions append Versions/A twice for the Mac privacy resource.
# Normalize only our assembly copy; never alter the vendor checkout or Mach-O.
python3 "${SCRIPT_DIR}/webrtc_privacy.py" "${XCFRAMEWORK_DIR}" --repair-known-macos-location
"${REPOSITORY_ROOT}/scripts/BuildWebRTC/verify-webrtc-xcframework.sh" "${XCFRAMEWORK_DIR}"

cd "${OUTPUT_DIR}"
artifact_zip="WebRTC-${WEBRTC_BRANCH//\//-}.xcframework.zip"
rm -f "${artifact_zip}" "${artifact_zip%.zip}.provenance.json"
zip --symlinks -r "${artifact_zip}" WebRTC.xcframework
if [[ "${ASSEMBLE_ONLY}" != "true" ]]; then
  (cd .. && verify_vendor_sources)
  built_revision="$(git rev-parse HEAD)"
  built_tools_revision="$(git -C "${DEPOT_TOOLS_DIR}" rev-parse HEAD)"
  if [[ "${built_revision}" != "${upstream_revision}" || "${built_tools_revision}" != "${depot_tools_revision}" ]]; then
    echo "WebRTC checkout or depot_tools changed during the build." >&2
    exit 1
  fi
  sdks=()
  if [[ "${IOS}" == "true" ]]; then sdks+=(iphoneos iphonesimulator); fi
  if [[ "${MACOS}" == "true" ]]; then sdks+=(macosx); fi
  python3 "${SCRIPT_DIR}/webrtc_provenance.py" "${artifact_zip}" \
    "${upstream_revision}" "${depot_tools_revision}" "${sdks[@]}"
fi
shasum -a 256 "${artifact_zip}"

echo "Built: ${XCFRAMEWORK_DIR}"
