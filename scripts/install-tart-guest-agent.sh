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

: "Resolve uploaded launch agent plist path (can vary with communicator user/home)"
resolve_uploaded_plist() {
  local candidate
  for candidate in \
    "${HOME:-}/tart-guest-agent.plist" \
    "/Users/${SUDO_USER:-}/tart-guest-agent.plist" \
    "/Users/${USER:-}/tart-guest-agent.plist" \
    "/Users/admin/tart-guest-agent.plist"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

UPLOADED_PLIST_PATH="$(resolve_uploaded_plist || true)"

if [[ -z "${UPLOADED_PLIST_PATH}" ]]; then
  : "Fallback: synthesize a valid launch agent plist when upload path is unavailable"
  UPLOADED_PLIST_PATH="${TMP_DIR}/tart-guest-agent.plist"
  cat > "${UPLOADED_PLIST_PATH}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>org.cirruslabs.tart-guest-agent</string>
    <key>ProgramArguments</key>
    <array>
      <string>/opt/tart-guest-agent/bin/tart-guest-agent</string>
      <string>--run-daemon</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/opt/tart-guest-agent/bin:/run/wrappers/bin:/run/current-system/sw/bin:/bin:/usr/bin:/usr/sbin:/usr/local/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>/var/empty</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/tart-guest-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tart-guest-agent.log</string>
  </dict>
</plist>
EOF
fi

: "Patch launch agent plist to match install location"
if sudo /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "${UPLOADED_PLIST_PATH}" >/dev/null 2>&1; then
  sudo /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /opt/tart-guest-agent/bin/tart-guest-agent" "${UPLOADED_PLIST_PATH}"
elif sudo /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "${UPLOADED_PLIST_PATH}" >/dev/null 2>&1; then
  sudo /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /opt/tart-guest-agent/bin/tart-guest-agent" "${UPLOADED_PLIST_PATH}"
elif sudo /usr/libexec/PlistBuddy -c "Print :Program" "${UPLOADED_PLIST_PATH}" >/dev/null 2>&1; then
  sudo /usr/libexec/PlistBuddy -c "Set :Program /opt/tart-guest-agent/bin/tart-guest-agent" "${UPLOADED_PLIST_PATH}"
else
  sudo /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "${UPLOADED_PLIST_PATH}"
  sudo /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /opt/tart-guest-agent/bin/tart-guest-agent" "${UPLOADED_PLIST_PATH}"
  sudo /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string --run-daemon" "${UPLOADED_PLIST_PATH}"
fi

: "Resolve primary user home and install launch agent plist into user LaunchAgents location"
resolve_existing_user() {
  local candidate
  for candidate in "$@"; do
    if [[ -z "${candidate}" ]]; then
      continue
    fi
    if dscl . -read "/Users/${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

PRIMARY_USER="$(resolve_existing_user "${PRIMARY_ACCOUNT_NAME:-}" "${TART_GUEST_AGENT_USER:-}" "${SUDO_USER:-}" "${USER:-}" admin || true)"
if [[ -z "${PRIMARY_USER}" ]]; then
  echo "Failed to resolve an existing user for tart-guest-agent installation." >&2
  echo "Tried: PRIMARY_ACCOUNT_NAME='${PRIMARY_ACCOUNT_NAME:-}', TART_GUEST_AGENT_USER='${TART_GUEST_AGENT_USER:-}', SUDO_USER='${SUDO_USER:-}', USER='${USER:-}', admin" >&2
  exit 1
fi

PRIMARY_HOME="$(dscl . -read "/Users/${PRIMARY_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${PRIMARY_HOME}" ]]; then
  PRIMARY_HOME="/Users/${PRIMARY_USER}"
fi
LAUNCH_AGENT_PATH="${PRIMARY_HOME}/Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist"

sudo install -d -m 0755 "${PRIMARY_HOME}/Library/LaunchAgents"
sudo mv "${UPLOADED_PLIST_PATH}" "${LAUNCH_AGENT_PATH}"
sudo chown "${PRIMARY_USER}:staff" "${LAUNCH_AGENT_PATH}"
sudo chmod 0644 "${LAUNCH_AGENT_PATH}"

: "Patch working directory to primary user home"
sudo /usr/libexec/PlistBuddy -c "Set :WorkingDirectory ${PRIMARY_HOME}" "${LAUNCH_AGENT_PATH}"

: "Validate launch agent plist syntax"
sudo plutil -lint "${LAUNCH_AGENT_PATH}"

: "Resolve target user/domain and bootstrap launch agent"
TARGET_USER="$(resolve_existing_user "${TART_GUEST_AGENT_USER:-}" "${PRIMARY_USER}" || true)"
if [[ -z "${TARGET_USER}" ]]; then
  echo "Failed to resolve target user for launchctl bootstrap." >&2
  echo "Tried: TART_GUEST_AGENT_USER='${TART_GUEST_AGENT_USER:-}', PRIMARY_USER='${PRIMARY_USER}'" >&2
  exit 1
fi

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
