#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
ENV_FILE="${SCRIPT_DIR}/.envrc"
if [[ ! -f "${ENV_FILE}" && -n "${MACOS_ENV_FILE:-}" ]]; then
  ENV_FILE="${MACOS_ENV_FILE}"
fi
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "Create temporary workspace"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

: "Resolve latest Darwin guest-agent release asset"
ASSET_URL=""
for REPO in cirruslabs/tart-guest-agent cirruslabs/tart; do
  JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" || true)"
  if [[ -z "${JSON}" ]]; then
    continue
  fi

  CANDIDATE_PRIMARY="$({
    printf '%s\n' "${JSON}" \
      | grep -E '"browser_download_url"' \
      | grep -E 'darwin' \
      | grep -E '(arm64|aarch64|universal)' \
      | grep -E '\.tar\.gz"' \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/'
  } || true)"

  CANDIDATE_FALLBACK="$({
    printf '%s\n' "${JSON}" \
      | grep -E '"browser_download_url"' \
      | grep -E 'darwin' \
      | grep -E '\.tar\.gz"' \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/'
  } || true)"

  CANDIDATE="${CANDIDATE_PRIMARY:-${CANDIDATE_FALLBACK}}"
  if [[ -n "${CANDIDATE}" ]]; then
    ASSET_URL="${CANDIDATE}"
    break
  fi
done

: "Fail fast if no matching release asset found"
if [[ -z "${ASSET_URL}" ]]; then
  echo 'Failed to locate a Darwin tart-guest-agent tarball in latest GitHub releases.' >&2
  exit 1
fi

echo "Selected tart-guest-agent asset URL: ${ASSET_URL}"

: "Download and unpack guest-agent tarball"
curl -fL "${ASSET_URL}" -o "${TMP_DIR}/tart-guest-agent.tar.gz"
tar -xzf "${TMP_DIR}/tart-guest-agent.tar.gz" -C "${TMP_DIR}"

: "Locate unpacked tart-guest-agent binary"
BIN_PATH="$(find "${TMP_DIR}" -type f -name tart-guest-agent | head -n 1 || true)"
if [[ -z "${BIN_PATH}" ]]; then
  echo 'tart-guest-agent binary not found in downloaded archive.' >&2
  exit 1
fi

: "Install binary into /opt/tart-guest-agent/bin"
sudo install -d -m 0755 /opt/tart-guest-agent/bin
sudo install -m 0755 "${BIN_PATH}" /opt/tart-guest-agent/bin/tart-guest-agent
test -x /opt/tart-guest-agent/bin/tart-guest-agent

: "Patch uploaded daemon plist to match install location"
sudo /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /opt/tart-guest-agent/bin/tart-guest-agent" ~/tart-guest-daemon.plist

: "Install daemon plist into launchd system location"
sudo mv ~/tart-guest-daemon.plist /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
sudo chown root:wheel /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
sudo chmod 0644 /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist

: "Validate daemon plist syntax"
sudo plutil -lint /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist

: "Reload and kickstart daemon"
sudo launchctl bootout system/org.cirruslabs.tart-guest-daemon >/dev/null 2>&1 || true
sudo launchctl bootstrap system /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
sudo launchctl enable system/org.cirruslabs.tart-guest-daemon || true
sudo launchctl kickstart -k system/org.cirruslabs.tart-guest-daemon || true
