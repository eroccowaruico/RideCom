# shellcheck shell=bash
# Keep vendor debug paths outside personal home directories by default.
if [[ -z "${WEBRTC_BUILD_ROOT:-}" ]]; then
  webrtc_user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
  WEBRTC_BUILD_ROOT="${webrtc_user_temp%/}/ridecom-webrtc-build"
fi

find_webrtc_candidate() {
  local output_dir="$1"
  local candidate candidates
  [[ -d "${output_dir}" ]] || return 0
  candidates="$(find "${output_dir}" -maxdepth 1 -type f -name 'WebRTC-*.xcframework.zip' -print)" || return
  candidates="$(sort -r <<< "${candidates}")" || return
  while IFS= read -r candidate; do
    if [[ -n "${candidate}" && -f "${candidate%.zip}.provenance.json" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done <<< "${candidates}"
}
