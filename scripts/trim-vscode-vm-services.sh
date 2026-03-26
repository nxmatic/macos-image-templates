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
: "${DISABLE_SPOTLIGHT_INDEXING:=1}"
: "${SPOTLIGHT_DISABLE_MDS_DAEMON:=1}"
: "${SPOTLIGHT_PURGE_ASSETS:=1}"
: "${DISABLE_MEDIA_ANALYSIS_DAEMONS:=1}"
: "${DISABLE_SIRI_AND_SUGGESTIONS:=1}"
: "${DISABLE_AIRDROP_CONTINUITY:=0}"
: "${SERVICE_TRIM_MODE:=disable}"

PRIMARY_UID="$(id -u "${PRIMARY_ACCOUNT_NAME}" 2>/dev/null || true)"

usage() {
  cat <<'EOF'
Usage:
  trim-vscode-vm-services [disable|enable]

Modes:
  disable  Apply VSCode-focused background-service trimming profile (default)
  enable   Re-activate services managed by this script

Environment:
  SERVICE_TRIM_MODE=disable|enable
  DISABLE_SPOTLIGHT_INDEXING=1
  SPOTLIGHT_DISABLE_MDS_DAEMON=1
  SPOTLIGHT_PURGE_ASSETS=1
  DISABLE_MEDIA_ANALYSIS_DAEMONS=1
  DISABLE_SIRI_AND_SUGGESTIONS=1
  DISABLE_AIRDROP_CONTINUITY=0
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  SERVICE_TRIM_MODE="${1}"
fi

disable_system_label() {
  local label="$1"
  sudo launchctl disable "system/${label}" >/dev/null 2>&1 || true
  sudo launchctl bootout "system/${label}" >/dev/null 2>&1 || true
}

enable_system_label() {
  local label="$1"
  local plist_path="/System/Library/LaunchDaemons/${label}.plist"

  sudo launchctl enable "system/${label}" >/dev/null 2>&1 || true
  if [[ -f "${plist_path}" ]]; then
    sudo launchctl bootstrap system "${plist_path}" >/dev/null 2>&1 || true
  fi
  sudo launchctl kickstart -k "system/${label}" >/dev/null 2>&1 || true
}

disable_user_label() {
  local uid="$1"
  local label="$2"

  [[ -z "${uid}" ]] && return 0

  sudo launchctl disable "gui/${uid}/${label}" >/dev/null 2>&1 || true
  sudo launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true

  sudo launchctl disable "user/${uid}/${label}" >/dev/null 2>&1 || true
  sudo launchctl bootout "user/${uid}/${label}" >/dev/null 2>&1 || true
}

enable_user_label() {
  local uid="$1"
  local label="$2"
  local plist_path="/System/Library/LaunchAgents/${label}.plist"

  [[ -z "${uid}" ]] && return 0

  for domain in "gui/${uid}" "user/${uid}"; do
    sudo launchctl enable "${domain}/${label}" >/dev/null 2>&1 || true
    if [[ -f "${plist_path}" ]]; then
      sudo launchctl bootstrap "${domain}" "${plist_path}" >/dev/null 2>&1 || true
    fi
    sudo launchctl kickstart -k "${domain}/${label}" >/dev/null 2>&1 || true
  done
}

list_apfs_mounts() {
  mount | awk -F ' on ' '/\(apfs/ { split($2, parts, " \\(" ); print parts[1] }'
}

case "${SERVICE_TRIM_MODE}" in
  disable)
    if [[ "${DISABLE_SPOTLIGHT_INDEXING}" == "1" ]]; then
      : "Disable Spotlight indexing and prevent rebuilds"
      sudo mdutil -a -i off || true

      while IFS= read -r mount_point; do
        [[ -z "${mount_point}" ]] && continue
        sudo mdutil -i off "${mount_point}" >/dev/null 2>&1 || true
        if [[ "${SPOTLIGHT_PURGE_ASSETS}" == "1" ]]; then
          if ! sudo mdutil -E "${mount_point}" >/dev/null 2>&1; then
            # Fallback cleanup when mdutil erase is unavailable for this mount.
            sudo rm -rf "${mount_point}/.Spotlight-V100" "${mount_point}/.Spotlight-V100.tmp" >/dev/null 2>&1 || true
          fi
        fi
        sudo touch "${mount_point}/.metadata_never_index" >/dev/null 2>&1 || true
      done < <(list_apfs_mounts)

      if [[ "${SPOTLIGHT_DISABLE_MDS_DAEMON}" == "1" ]]; then
        disable_system_label com.apple.metadata.mds
        sudo killall mds mds_stores mdworker mdworker_shared >/dev/null 2>&1 || true
      fi
    fi

    if [[ "${DISABLE_MEDIA_ANALYSIS_DAEMONS}" == "1" ]]; then
      : "Disable media/photo analysis daemons"
      disable_system_label com.apple.mediaanalysisd
      disable_system_label com.apple.photoanalysisd
      disable_user_label "${PRIMARY_UID}" com.apple.mediaanalysisd
      disable_user_label "${PRIMARY_UID}" com.apple.photoanalysisd
    fi

    if [[ "${DISABLE_SIRI_AND_SUGGESTIONS}" == "1" ]]; then
      : "Disable Siri/suggestions style user agents for primary user"
      disable_user_label "${PRIMARY_UID}" com.apple.assistantd
      disable_user_label "${PRIMARY_UID}" com.apple.parsecd
      disable_user_label "${PRIMARY_UID}" com.apple.suggestd
      disable_user_label "${PRIMARY_UID}" com.apple.knowledge-agent
    fi

    if [[ "${DISABLE_AIRDROP_CONTINUITY}" == "1" ]]; then
      : "Disable continuity and nearby-sharing style user agents for primary user"
      disable_user_label "${PRIMARY_UID}" com.apple.sharingd
      disable_user_label "${PRIMARY_UID}" com.apple.coreservices.useractivityd
    fi

    echo "Background service trimming complete for VSCode-focused VM profile (disable mode)."
    ;;
  enable)
    : "Re-enable services managed by this script"

    if [[ "${DISABLE_SPOTLIGHT_INDEXING}" == "1" ]]; then
      sudo mdutil -a -i on || true
      while IFS= read -r mount_point; do
        [[ -z "${mount_point}" ]] && continue
        sudo mdutil -i on "${mount_point}" >/dev/null 2>&1 || true
        sudo rm -f "${mount_point}/.metadata_never_index" >/dev/null 2>&1 || true
      done < <(list_apfs_mounts)

      if [[ "${SPOTLIGHT_DISABLE_MDS_DAEMON}" == "1" ]]; then
        enable_system_label com.apple.metadata.mds
      fi
    fi

    if [[ "${DISABLE_MEDIA_ANALYSIS_DAEMONS}" == "1" ]]; then
      enable_system_label com.apple.mediaanalysisd
      enable_system_label com.apple.photoanalysisd
      enable_user_label "${PRIMARY_UID}" com.apple.mediaanalysisd
      enable_user_label "${PRIMARY_UID}" com.apple.photoanalysisd
    fi

    if [[ "${DISABLE_SIRI_AND_SUGGESTIONS}" == "1" ]]; then
      enable_user_label "${PRIMARY_UID}" com.apple.assistantd
      enable_user_label "${PRIMARY_UID}" com.apple.parsecd
      enable_user_label "${PRIMARY_UID}" com.apple.suggestd
      enable_user_label "${PRIMARY_UID}" com.apple.knowledge-agent
    fi

    if [[ "${DISABLE_AIRDROP_CONTINUITY}" == "1" ]]; then
      enable_user_label "${PRIMARY_UID}" com.apple.sharingd
      enable_user_label "${PRIMARY_UID}" com.apple.coreservices.useractivityd
    fi

    echo "Background service re-activation complete for VSCode-focused VM profile (enable mode)."
    ;;
  *)
    echo "Invalid SERVICE_TRIM_MODE: ${SERVICE_TRIM_MODE}. Expected 'disable' or 'enable'." >&2
    usage
    exit 1
    ;;
esac