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

: "${PRIMARY_ACCOUNT_NAME:=nxmatic}"
: "${SECONDARY_ADMIN_ENABLE:=1}"
: "${SECONDARY_ADMIN_NAME:=admin}"
: "${SECONDARY_ADMIN_FULL_NAME:=Stephane Lacoin (aka admin)}"
: "${SECONDARY_ADMIN_HOME:=/Users/admin}"
: "${SECONDARY_ADMIN_PASSWORD:=admin}"
: "${SECONDARY_ADMIN_HOME_MODE:=700}"
: "${SECONDARY_ADMIN_STRIP_ACL:=1}"
: "${SECONDARY_ADMIN_CLEAR_QUARANTINE:=1}"
: "${SECONDARY_ADMIN_STRIP_XATTRS:=0}"

if [[ "${SECONDARY_ADMIN_ENABLE}" != "1" ]]; then
  echo "Secondary admin user provisioning disabled (SECONDARY_ADMIN_ENABLE=${SECONDARY_ADMIN_ENABLE})."
  exit 0
fi

if [[ "${SECONDARY_ADMIN_NAME}" == "${PRIMARY_ACCOUNT_NAME}" ]]; then
  echo "Skipping secondary admin provisioning: SECONDARY_ADMIN_NAME matches PRIMARY_ACCOUNT_NAME (${PRIMARY_ACCOUNT_NAME})."
  exit 0
fi

if dscl . -read "/Users/${SECONDARY_ADMIN_NAME}" >/dev/null 2>&1; then
  echo "Secondary admin '${SECONDARY_ADMIN_NAME}' already exists; reconciling metadata."
  sudo dscl . -create "/Users/${SECONDARY_ADMIN_NAME}" RealName "${SECONDARY_ADMIN_FULL_NAME}" || true
  sudo dscl . -create "/Users/${SECONDARY_ADMIN_NAME}" NFSHomeDirectory "${SECONDARY_ADMIN_HOME}" || true
else
  sudo sysadminctl -addUser "${SECONDARY_ADMIN_NAME}" -fullName "${SECONDARY_ADMIN_FULL_NAME}" -home "${SECONDARY_ADMIN_HOME}" -password "${SECONDARY_ADMIN_PASSWORD}" -admin || true
fi

if ! dscl . -read "/Users/${SECONDARY_ADMIN_NAME}" >/dev/null 2>&1; then
  echo "Warning: unable to ensure secondary admin user '${SECONDARY_ADMIN_NAME}'."
  exit 0
fi

sudo mkdir -p "${SECONDARY_ADMIN_HOME}"
sudo chown -R "${SECONDARY_ADMIN_NAME}:staff" "${SECONDARY_ADMIN_HOME}" >/dev/null 2>&1 || true
if [[ "${SECONDARY_ADMIN_STRIP_ACL}" == "1" ]]; then
  sudo chmod -RN "${SECONDARY_ADMIN_HOME}" >/dev/null 2>&1 || true
fi
if [[ "${SECONDARY_ADMIN_CLEAR_QUARANTINE}" == "1" ]] && command -v xattr >/dev/null 2>&1; then
  sudo xattr -dr com.apple.quarantine "${SECONDARY_ADMIN_HOME}" >/dev/null 2>&1 || true
fi
if [[ "${SECONDARY_ADMIN_STRIP_XATTRS}" == "1" ]] && command -v xattr >/dev/null 2>&1; then
  sudo xattr -cr "${SECONDARY_ADMIN_HOME}" >/dev/null 2>&1 || true
fi
sudo chmod -R u+rwX "${SECONDARY_ADMIN_HOME}" >/dev/null 2>&1 || true
sudo chmod "${SECONDARY_ADMIN_HOME_MODE}" "${SECONDARY_ADMIN_HOME}" >/dev/null 2>&1 || true

sudo dscl . -create "/Users/${SECONDARY_ADMIN_NAME}" NFSHomeDirectory "${SECONDARY_ADMIN_HOME}" || true
sudo dscl . -create "/Users/${SECONDARY_ADMIN_NAME}" RealName "${SECONDARY_ADMIN_FULL_NAME}" || true

# Keep parity with primary-user sudo behavior for automation convenience.
sudo sh -c "mkdir -p /etc/sudoers.d/; echo '${SECONDARY_ADMIN_NAME} ALL=(ALL) NOPASSWD: ALL' | EDITOR=tee visudo /etc/sudoers.d/${SECONDARY_ADMIN_NAME}-nopasswd"

echo "Secondary admin user ensured: ${SECONDARY_ADMIN_NAME} (home=${SECONDARY_ADMIN_HOME})"
