#!/usr/bin/env bash
set -euo pipefail

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
: "${CACHE_MANAGER_USER:=${DATA_HOME_USER}}"

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

CACHE_HOME="$(resolve_home_dir_for_user "${CACHE_MANAGER_USER}")"

declare -A TARGET_PATHS
TARGET_PATHS[m2]="${CACHE_HOME}/.m2"
TARGET_PATHS[npm]="${CACHE_HOME}/.npm"
TARGET_PATHS[cache]="${CACHE_HOME}/.cache"
TARGET_PATHS[go]="${CACHE_HOME}/go"
TARGET_PATHS[lima]="${CACHE_HOME}/.lima"
TARGET_PATHS[tart]="${CACHE_HOME}/.tart"
TARGET_PATHS[jetbrains]="${CACHE_HOME}/Library/Caches/JetBrains"
TARGET_PATHS[poetry]="${CACHE_HOME}/Library/Caches/pypoetry"
TARGET_PATHS[jdt]="${CACHE_HOME}/Library/Caches/.jdt"
TARGET_PATHS[pip]="${CACHE_HOME}/Library/Caches/pip"
TARGET_PATHS[gopls]="${CACHE_HOME}/Library/Caches/gopls"
TARGET_PATHS[goimports]="${CACHE_HOME}/Library/Caches/goimports"
TARGET_PATHS[go-cache]="${CACHE_HOME}/Library/Caches/go"
TARGET_PATHS[lib-caches]="${CACHE_HOME}/Library/Caches"
TARGET_PATHS[app-support]="${CACHE_HOME}/Library/Application Support"
TARGET_PATHS[code-insiders]="${CACHE_HOME}/Library/Application Support/Code - Insiders"
TARGET_PATHS[code]="${CACHE_HOME}/Library/Application Support/Code"
TARGET_PATHS[comet]="${CACHE_HOME}/Library/Application Support/Comet"
TARGET_PATHS[jetbrains-app]="${CACHE_HOME}/Library/Application Support/JetBrains"

usage() {
  cat <<'EOF'
Usage:
  sudo manage-cache-volumes list
  sudo manage-cache-volumes reset <target|all>
  sudo manage-cache-volumes quota <target|all> <size>
  sudo manage-cache-volumes reserve <target|all> <size>

Examples:
  sudo manage-cache-volumes list
  sudo manage-cache-volumes reset cache
  sudo manage-cache-volumes reset all
  sudo manage-cache-volumes quota m2 8g
  sudo manage-cache-volumes quota all 20g

Notes:
  - Targets refer to mounted cache directories under the primary user's home.
  - reset clears contents but keeps mount points/volumes.
  - quota/reserve operate on the APFS volume mounted at the target path.
EOF
}

is_mounted_at_path() {
  local path="$1"
  mount | grep -Fq " on ${path} ("
}

device_id_for_path() {
  local path="$1"
  diskutil info -plist "${path}" | plutil -extract DeviceIdentifier raw -o - - 2>/dev/null || true
}

iter_targets() {
  local selector="$1"
  if [[ "${selector}" == "all" ]]; then
    printf '%s\n' "${!TARGET_PATHS[@]}" | sort
  else
    printf '%s\n' "${selector}"
  fi
}

list_targets() {
  local key path mounted dev usage
  for key in $(printf '%s\n' "${!TARGET_PATHS[@]}" | sort); do
    path="${TARGET_PATHS[${key}]}"
    if [[ ! -e "${path}" ]]; then
      printf '%-14s missing    %s\n' "${key}" "${path}"
      continue
    fi

    if is_mounted_at_path "${path}"; then
      mounted="mounted"
      dev="$(device_id_for_path "${path}")"
    else
      mounted="not-mounted"
      dev="-"
    fi

    usage="$(du -sh "${path}" 2>/dev/null | awk '{print $1}' || echo '?')"
    printf '%-14s %-11s %-8s %-10s %s\n' "${key}" "${mounted}" "${usage}" "${dev}" "${path}"
  done
}

reset_target() {
  local key="$1"
  local path="${TARGET_PATHS[${key}]:-}"

  if [[ -z "${path}" ]]; then
    echo "Unknown target: ${key}" >&2
    return 1
  fi
  if [[ ! -d "${path}" ]]; then
    echo "Skipping ${key}: path not found (${path})"
    return 0
  fi

  echo "Resetting ${key} at ${path}"
  sudo find "${path}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

apply_quota_like() {
  local mode="$1" # quota|reserve
  local key="$2"
  local size="$3"
  local path="${TARGET_PATHS[${key}]:-}"
  local dev

  if [[ -z "${path}" ]]; then
    echo "Unknown target: ${key}" >&2
    return 1
  fi
  if [[ ! -e "${path}" ]]; then
    echo "Skipping ${key}: path not found (${path})"
    return 0
  fi
  if ! is_mounted_at_path "${path}"; then
    echo "Skipping ${key}: not mounted at ${path}"
    return 0
  fi

  dev="$(device_id_for_path "${path}")"
  if [[ -z "${dev}" ]]; then
    echo "Skipping ${key}: cannot resolve APFS device for ${path}" >&2
    return 0
  fi

  if [[ "${mode}" == "quota" ]]; then
    echo "Setting quota for ${key} (${dev}) to ${size}"
    sudo diskutil apfs setVolumeQuota "${dev}" "${size}"
  else
    echo "Setting reserve for ${key} (${dev}) to ${size}"
    sudo diskutil apfs setVolumeReserve "${dev}" "${size}"
  fi
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    list)
      list_targets
      ;;
    reset)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      local selector="$1"
      local key
      while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        reset_target "${key}"
      done < <(iter_targets "${selector}")
      ;;
    quota|reserve)
      [[ $# -eq 2 ]] || { usage; exit 1; }
      local selector="$1"
      local size="$2"
      local key
      while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        apply_quota_like "${cmd}" "${key}" "${size}"
      done < <(iter_targets "${selector}")
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
