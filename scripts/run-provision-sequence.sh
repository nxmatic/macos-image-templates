#!/usr/bin/env bash
set -euo pipefail

: "${VM_SCRIPTS_DIR:=/private/tmp/scripts}"
: "${ENV_POINTER_FILE:=/private/tmp/macos-image-template.envrc.path}"
: "${STATUS_DIR:=/private/var/run/macos-image-template-provision}"
: "${LOG_DIR:=/private/var/log/macos-image-template-provision}"
: "${FORCE_RERUN:=0}"

: "${NIX_INSTALLER_URL:=https://artifacts.nixos.org/nix-installer}"
: "${NIX_INSTALLER_PATH:=/private/tmp/nix-installer}"
: "${NIX_INSTALL_AT_BUILD:=1}"

if [[ -f "${ENV_POINTER_FILE}" && -z "${MACOS_ENV_FILE:-}" ]]; then
  MACOS_ENV_FILE="$(cat "${ENV_POINTER_FILE}")"
fi
if [[ -z "${MACOS_ENV_FILE:-}" ]]; then
  MACOS_ENV_FILE="${VM_SCRIPTS_DIR}/.envrc"
fi

usage() {
  cat <<'EOF'
Usage:
  run-provision-sequence [--force]

Options:
  --force  Re-run steps even if a success marker exists.

Behavior:
  - Runs provisioning scripts in sequence.
  - Skips scripts that already have a success marker unless --force is used.
  - Writes step status markers under /private/var/run/macos-image-template-provision.
  - Writes stderr logs under /private/var/log/macos-image-template-provision/*.stderr.log.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--force" ]]; then
  FORCE_RERUN=1
elif [[ $# -gt 0 ]]; then
  usage
  exit 1
fi

mkdir -p "${STATUS_DIR}" "${LOG_DIR}"

STEPS=(
  provision-base-system.sh
  trim-vscode-vm-services.sh
  install-tart-guest-agent.sh
  setup-data-disk.sh
  install-nix-installer.sh
  resize-system-container.sh
  rename-primary-user-if-vanilla.sh
  ensure-secondary-admin-user.sh
  install-user-tart-sbin.sh
)

run_step() {
  local script_name="$1"
  local step_name="${script_name%.sh}"
  local script_path="${VM_SCRIPTS_DIR}/${script_name}"
  local ok_file="${STATUS_DIR}/${step_name}.ok"
  local failed_file="${STATUS_DIR}/${step_name}.failed"
  local stderr_log="${LOG_DIR}/${step_name}.stderr.log"
  local stdout_log="${LOG_DIR}/${step_name}.stdout.log"

  if [[ "${FORCE_RERUN}" != "1" && -f "${ok_file}" ]]; then
    echo "[skip] ${step_name} (already successful)"
    return 0
  fi

  if [[ ! -x "${script_path}" && ! -f "${script_path}" ]]; then
    echo "[error] missing script: ${script_path}" >&2
    return 1
  fi

  rm -f "${failed_file}"
  : > "${stderr_log}"
  : > "${stdout_log}"

  echo "[run ] ${step_name}"

  if (
    set -euo pipefail
    exec 2> >(tee -a "${stderr_log}" >&2)
    if [[ "${script_name}" == "install-nix-installer.sh" ]]; then
      env \
        MACOS_ENV_FILE="${MACOS_ENV_FILE}" \
        NIX_INSTALLER_URL="${NIX_INSTALLER_URL}" \
        NIX_INSTALLER_PATH="${NIX_INSTALLER_PATH}" \
        NIX_INSTALL_AT_BUILD="${NIX_INSTALL_AT_BUILD}" \
        bash -euxo pipefail "${script_path}"
    else
      env MACOS_ENV_FILE="${MACOS_ENV_FILE}" bash -euxo pipefail "${script_path}"
    fi
  ) | tee -a "${stdout_log}"; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${ok_file}"
    rm -f "${failed_file}"
    echo "[ ok ] ${step_name}"
  else
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${failed_file}"
    echo "[fail] ${step_name} (see ${stderr_log})" >&2
    return 1
  fi
}

for script_name in "${STEPS[@]}"; do
  run_step "${script_name}"
done

echo "All provisioning steps completed."
