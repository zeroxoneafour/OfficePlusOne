#!/usr/bin/env bash
#
# setup_android_xr.sh
#
# Idempotent installer for the Godot OpenXR Vendors addon
# (https://github.com/GodotVR/godot_openxr_vendors), required for the
# "Android XR (Quest)" export preset (Meta vendor plugin, gradle build).
#
# Downloads the latest GitHub release compatible with Godot 4.6+ (which
# includes 4.7.x) and unpacks only the addon folder into
# addons/godotopenxrvendors/, overwriting any previous install so this
# script is safe to re-run.
#
# Usage: tools/setup_android_xr.sh
#
set -euo pipefail

REPO="GodotVR/godot_openxr_vendors"
ASSET_NAME="godotopenxrvendorsaddon.zip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADDON_DEST="${PROJECT_ROOT}/addons/godotopenxrvendors"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log()  { printf '[setup_android_xr] %s\n' "$1"; }
fail() { printf '[setup_android_xr] ERROR: %s\n' "$1" >&2; exit 1; }

command -v curl  >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v unzip >/dev/null 2>&1 || fail "unzip is required but not found on PATH."

log "Querying GitHub API for the latest release of ${REPO}..."
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

CURL_AUTH_ARGS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

if ! RELEASE_JSON="$(curl -fsSL "${CURL_AUTH_ARGS[@]}" "${API_URL}")"; then
  fail "Could not reach the GitHub API (network unavailable?). No changes made. You can re-run this script later, or manually download ${ASSET_NAME} from https://github.com/${REPO}/releases/latest and unzip its 'asset/addons/godotopenxrvendors' folder into addons/godotopenxrvendors/."
fi

# Extract fields with plain grep/sed so this script has no dependency on jq.
TAG_NAME="$(printf '%s' "${RELEASE_JSON}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
[[ -n "${TAG_NAME}" ]] || fail "Could not parse tag_name from GitHub API response."

DOWNLOAD_URL="$(printf '%s' "${RELEASE_JSON}" | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_NAME}\"" | head -n1 | sed -E 's/.*"(https:[^"]+)"/\1/')"
[[ -n "${DOWNLOAD_URL}" ]] || fail "Release ${TAG_NAME} does not have an asset named ${ASSET_NAME}."

log "Latest compatible release: ${TAG_NAME}"
log "Downloading ${ASSET_NAME}..."

ZIP_PATH="${TMP_DIR}/${ASSET_NAME}"
if ! curl -fsSL "${CURL_AUTH_ARGS[@]}" -o "${ZIP_PATH}" "${DOWNLOAD_URL}"; then
  fail "Download failed (network unavailable?). No changes made. You can re-run this script later, or manually download ${ASSET_NAME} from ${DOWNLOAD_URL} and unzip its 'asset/addons/godotopenxrvendors' folder into addons/godotopenxrvendors/."
fi

log "Extracting addon files..."
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"
# Only unzip the addon folder (asset/addons/godotopenxrvendors/**), not the
# other top-level files/samples that may be bundled in the release asset.
unzip -q "${ZIP_PATH}" "asset/addons/godotopenxrvendors/*" -d "${EXTRACT_DIR}"

SRC_ADDON_DIR="${EXTRACT_DIR}/asset/addons/godotopenxrvendors"
[[ -d "${SRC_ADDON_DIR}" ]] || fail "Expected folder asset/addons/godotopenxrvendors was not found in the downloaded archive."

log "Installing into $(realpath --relative-to="${PROJECT_ROOT}" "${ADDON_DEST}" 2>/dev/null || echo "${ADDON_DEST}")..."
mkdir -p "${PROJECT_ROOT}/addons"
rm -rf "${ADDON_DEST}"
mv "${SRC_ADDON_DIR}" "${ADDON_DEST}"

# Stamp the installed version so future runs / humans can tell what's there.
echo "${TAG_NAME}" > "${ADDON_DEST}/.godot_openxr_vendors_version"

log "Installed godot_openxr_vendors ${TAG_NAME} into addons/godotopenxrvendors/"
log ""
log "Next steps:"
log "  1. Open the project in the Godot 4.7 editor once so it can import the new addon."
log "  2. This addon ships as a GDExtension (plugin.gdextension) with no plugin.cfg,"
log "     so it does NOT need an entry in project.godot's [editor_plugins] enabled list"
log "     - it loads automatically once the .gdextension file is present."
log "  3. Editor > Project > Install Android Build Template (writes res://android/build)."
log "  4. Editor Settings > Export > Android: set the Android SDK path (and, if needed,"
log "     the JDK path / debug keystore) so on-device export and 'one-click deploy' work."
log "  5. Use the 'Android XR (Quest)' export preset in export_presets.cfg; it already"
log "     enables gradle build + the Meta OpenXR vendor plugin."
log "  6. Put your Quest in Developer Mode, connect via adb (USB or wireless), and use"
log "     Project > Export or Godot's one-click deploy to install the APK."
