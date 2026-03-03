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

: "Patch uploaded launch agent plist to match install location"
sudo /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /opt/tart-guest-agent/bin/tart-guest-agent" ~/tart-guest-agent.plist

: "Resolve primary user home and install launch agent plist into user LaunchAgents location"
PRIMARY_USER="${PRIMARY_ACCOUNT_NAME:-${TART_GUEST_AGENT_USER:-${SUDO_USER:-${USER}}}}"
PRIMARY_HOME="$(dscl . -read "/Users/${PRIMARY_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${PRIMARY_HOME}" ]]; then
  PRIMARY_HOME="/Users/${PRIMARY_USER}"
fi
LAUNCH_AGENT_PATH="${PRIMARY_HOME}/Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist"

sudo install -d -m 0755 "${PRIMARY_HOME}/Library/LaunchAgents"
sudo mv ~/tart-guest-agent.plist "${LAUNCH_AGENT_PATH}"
sudo chown "${PRIMARY_USER}:staff" "${LAUNCH_AGENT_PATH}"
sudo chmod 0644 "${LAUNCH_AGENT_PATH}"

: "Patch working directory to primary user home"
sudo /usr/libexec/PlistBuddy -c "Set :WorkingDirectory ${PRIMARY_HOME}" "${LAUNCH_AGENT_PATH}"

: "Validate launch agent plist syntax"
sudo plutil -lint "${LAUNCH_AGENT_PATH}"

: "Resolve target user/domain and bootstrap launch agent"
TARGET_USER="${TART_GUEST_AGENT_USER:-${PRIMARY_USER}}"
TARGET_UID="$(id -u "${TARGET_USER}")"
DOMAIN="gui/${TARGET_UID}"
if ! sudo launchctl print "${DOMAIN}" >/dev/null 2>&1; then
  DOMAIN="user/${TARGET_UID}"
fi

sudo launchctl bootout "${DOMAIN}/org.cirruslabs.tart-guest-agent" >/dev/null 2>&1 || true
sudo launchctl bootstrap "${DOMAIN}" "${LAUNCH_AGENT_PATH}"
sudo launchctl enable "${DOMAIN}/org.cirruslabs.tart-guest-agent" || true
sudo launchctl kickstart -k "${DOMAIN}/org.cirruslabs.tart-guest-agent" || true

: "Best-effort cleanup of legacy system daemon if present"
sudo launchctl bootout system/org.cirruslabs.tart-guest-daemon >/dev/null 2>&1 || true
if [[ -f /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist ]]; then
  sudo rm -f /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
fi

: "Best-effort cleanup of global LaunchAgents copy if present"
if [[ -f /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist ]]; then
  sudo rm -f /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
fi
