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
: "${DATA_HOME_USER:=${PRIMARY_ACCOUNT_NAME}}"
: "${RELAX_PERMS_USER:=${DATA_HOME_USER}}"
: "${RELAX_PERMS_STRIP_ACL:=1}"
: "${RELAX_PERMS_CLEAR_QUARANTINE:=1}"
: "${RELAX_PERMS_STRIP_XATTRS:=0}"
: "${RELAX_PERMS_HOME_MODE:=700}"
: "${RELAX_PERMS_INCLUDE_SECONDARY_ADMIN:=1}"
: "${SECONDARY_ADMIN_ENABLE:=1}"
: "${SECONDARY_ADMIN_NAME:=admin}"
: "${SECONDARY_ADMIN_HOME:=/Users/admin}"
: "${LIB_CACHES_BASE_REL_PATH:=Library/Caches}"
: "${LIB_CACHES_SUBVOLUME_SPECS:=jetbrains:JetBrains poetry:pypoetry jdt:.jdt pip:pip gopls:gopls goimports:goimports go:go}"

resolve_home_dir_for_user() {
  local user="$1"
  local dscl_home

  dscl_home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  if [[ -n "${dscl_home}" ]]; then
    echo "${dscl_home}"
    return 0
  fi

  echo "/Users/${user}"
}

normalize_path() {
  local user="$1"
  local path="$2"
  local mode="${3:-}"

  [[ -z "${user:-}" || -z "${path:-}" || ! -e "${path}" ]] && return 0

  sudo chown -R "${user}:staff" "${path}" >/dev/null 2>&1 || true

  if [[ "${RELAX_PERMS_STRIP_ACL}" == "1" ]]; then
    sudo chmod -RN "${path}" >/dev/null 2>&1 || true
  fi
  if [[ "${RELAX_PERMS_CLEAR_QUARANTINE}" == "1" ]] && command -v xattr >/dev/null 2>&1; then
    sudo xattr -dr com.apple.quarantine "${path}" >/dev/null 2>&1 || true
  fi
  if [[ "${RELAX_PERMS_STRIP_XATTRS}" == "1" ]] && command -v xattr >/dev/null 2>&1; then
    sudo xattr -cr "${path}" >/dev/null 2>&1 || true
  fi

  sudo chmod -R u+rwX "${path}" >/dev/null 2>&1 || true
  if [[ -n "${mode}" ]]; then
    sudo chmod "${mode}" "${path}" >/dev/null 2>&1 || true
  fi
}

RELAX_HOME="$(resolve_home_dir_for_user "${RELAX_PERMS_USER}")"

TARGETS=(
  "${RELAX_HOME}"
  "${RELAX_HOME}/.m2"
  "${RELAX_HOME}/.npm"
  "${RELAX_HOME}/.cache"
  "${RELAX_HOME}/go"
  "${RELAX_HOME}/.lima"
  "${RELAX_HOME}/.tart"
)

for spec in ${LIB_CACHES_SUBVOLUME_SPECS}; do
  cache_rel_path="${spec#*:}"
  TARGETS+=("${RELAX_HOME}/${LIB_CACHES_BASE_REL_PATH}/${cache_rel_path}")
done

for target in "${TARGETS[@]}"; do
  if [[ "${target}" == "${RELAX_HOME}" ]]; then
    normalize_path "${RELAX_PERMS_USER}" "${target}" "${RELAX_PERMS_HOME_MODE}"
  else
    normalize_path "${RELAX_PERMS_USER}" "${target}"
  fi
done

if [[ "${RELAX_PERMS_INCLUDE_SECONDARY_ADMIN}" == "1" && "${SECONDARY_ADMIN_ENABLE}" == "1" ]]; then
  normalize_path "${SECONDARY_ADMIN_NAME}" "${SECONDARY_ADMIN_HOME}" "${RELAX_PERMS_HOME_MODE}"
fi

echo "Relaxed managed permissions/xattrs for user '${RELAX_PERMS_USER}'."
