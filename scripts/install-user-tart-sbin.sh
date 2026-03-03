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

: "${PRIMARY_ACCOUNT_NAME:=admin}"
: "${TART_USER_SBIN_REL_PATH:=.tart/sbin}"

PRIMARY_HOME="$(dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${PRIMARY_HOME}" ]]; then
  PRIMARY_HOME="/Users/${PRIMARY_ACCOUNT_NAME}"
fi

TARGET_DIR="${PRIMARY_HOME}/${TART_USER_SBIN_REL_PATH}"
sudo install -d -m 0755 "${TARGET_DIR}"

install_helper() {
  local src_name="$1"
  local dst_name="$2"

  if [[ ! -f "${SCRIPT_DIR}/${src_name}" ]]; then
    echo "Warning: source script missing: ${SCRIPT_DIR}/${src_name}" >&2
    return 0
  fi

  sudo install -m 0755 "${SCRIPT_DIR}/${src_name}" "${TARGET_DIR}/${dst_name}"
  sudo chown "${PRIMARY_ACCOUNT_NAME}:staff" "${TARGET_DIR}/${dst_name}" || true
}

install_helper "manage-cache-volumes.sh" "manage-cache-volumes"
install_helper "relax-user-permissions.sh" "relax-user-permissions"
install_helper "run-provision-sequence.sh" "run-provision-sequence"
install_helper "trim-vscode-vm-services.sh" "trim-vscode-vm-services"
install_helper "install-tart-guest-agent.sh" "install-tart-guest-agent"

echo "Installed helper scripts to ${TARGET_DIR} for ${PRIMARY_ACCOUNT_NAME}."