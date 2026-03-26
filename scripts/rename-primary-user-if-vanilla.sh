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

: "${MACOS_BUILD_SOURCE_MODE:=clone}"
: "${PRIMARY_ACCOUNT_NAME:=admin}"
: "${PRIMARY_ACCOUNT_FULL_NAME:=Stephane Lacoin (aka nxmatic)}"
: "${PRIMARY_ACCOUNT_ALIAS:=nxmatic}"

if [[ "${MACOS_BUILD_SOURCE_MODE}" != "clone" ]]; then
  echo "Skipping account short-name migration: build source mode is '${MACOS_BUILD_SOURCE_MODE}' (only applies to clone)."
  exit 0
fi

if [[ "${PRIMARY_ACCOUNT_NAME}" == "admin" ]]; then
  echo "Skipping account short-name migration: PRIMARY_ACCOUNT_NAME is already 'admin'."
  exit 0
fi

if dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1; then
  echo "Target account '${PRIMARY_ACCOUNT_NAME}' already exists; no rename needed."
  exit 0
fi

if ! dscl . -read /Users/admin >/dev/null 2>&1; then
  echo "Warning: source account 'admin' not found; cannot rename to '${PRIMARY_ACCOUNT_NAME}'."
  exit 0
fi

OLD_HOME="$(dscl . -read /Users/admin NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${OLD_HOME}" ]]; then
  OLD_HOME="/Users/admin"
fi
NEW_HOME="/Users/${PRIMARY_ACCOUNT_NAME}"

# Prefer sysadminctl for account rename; fall back to dscl RecordName mutation.
if ! sudo sysadminctl -renameUser admin -newName "${PRIMARY_ACCOUNT_NAME}"; then
  echo "Warning: sysadminctl rename failed, attempting dscl RecordName fallback."
  sudo dscl . -change /Users/admin RecordName admin "${PRIMARY_ACCOUNT_NAME}" || true
fi

USER_RECORD_PATH="/Users/${PRIMARY_ACCOUNT_NAME}"
if ! dscl . -read "${USER_RECORD_PATH}" >/dev/null 2>&1 && dscl . -read /Users/admin >/dev/null 2>&1; then
  USER_RECORD_PATH="/Users/admin"
fi

if [[ "${OLD_HOME}" != "${NEW_HOME}" ]]; then
  if [[ -d "${OLD_HOME}" && ! -e "${NEW_HOME}" ]]; then
    sudo mv "${OLD_HOME}" "${NEW_HOME}" || true
  fi
  sudo dscl . -create "${USER_RECORD_PATH}" NFSHomeDirectory "${NEW_HOME}" || true
fi

sudo dscl . -create "${USER_RECORD_PATH}" RealName "${PRIMARY_ACCOUNT_FULL_NAME}" || true

if [[ -n "${PRIMARY_ACCOUNT_ALIAS}" && "${PRIMARY_ACCOUNT_ALIAS}" != "${PRIMARY_ACCOUNT_NAME}" ]]; then
  EXISTING_RECORD_NAMES="$(dscl . -read "${USER_RECORD_PATH}" RecordName 2>/dev/null || true)"
  if ! grep -Eq "(^|[[:space:]])${PRIMARY_ACCOUNT_ALIAS}([[:space:]]|$)" <<<"${EXISTING_RECORD_NAMES}"; then
    sudo dscl . -append "${USER_RECORD_PATH}" RecordName "${PRIMARY_ACCOUNT_ALIAS}" || true
  fi
fi

# Keep autologin aligned with the renamed short name.
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${PRIMARY_ACCOUNT_NAME}"

# Ensure sudoers entry exists for the renamed account.
sudo sh -c "mkdir -p /etc/sudoers.d/; echo '${PRIMARY_ACCOUNT_NAME} ALL=(ALL) NOPASSWD: ALL' | EDITOR=tee visudo /etc/sudoers.d/${PRIMARY_ACCOUNT_NAME}-nopasswd"

echo "Primary account rename complete for clone mode: admin -> ${PRIMARY_ACCOUNT_NAME}"
