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

: "${USER_DATA_DISK_INITIAL_SIZE_GB:=64}"
: "${USER_LIBRARY_DISK_INITIAL_SIZE_GB:=20}"
: "${GIT_STORE_DISK_INITIAL_SIZE_GB:=12}"
: "${NIX_STORE_DISK_INITIAL_SIZE_GB:=90}"
: "${BUILD_CHAINS_DISK_INITIAL_SIZE_GB:=16}"
: "${VM_IMAGES_DISK_INITIAL_SIZE_GB:=120}"
: "${DATA_DISK_NAME:=User Data}"
: "${DATA_DISK_USER_DATA_NAME:=${DATA_DISK_NAME}}"
: "${DATA_DISK_USER_LIBRARY_NAME:=User Library}"
: "${DATA_DISK_GIT_STORE_NAME:=Git Store}"
: "${DATA_DISK_NIX_STORE_NAME:=Nix Store}"
: "${DATA_DISK_BUILD_CHAINS_NAME:=Build Cache}"
: "${DATA_DISK_VM_IMAGES_NAME:=VM Images}"
: "${DATA_RELOCATE_LIBRARY:=0}"
: "${DATA_HOME_PARENT_DIR:=user-home}"
: "${DATA_COPY_USER_LIBRARY:=1}"
: "${DATA_COPY_GIT_STORE:=1}"
: "${DATA_COPY_NIX_STORE:=0}"
: "${DATA_COPY_BUILD_CHAINS:=1}"
: "${DATA_RELOCATE_USERS_ROOT:=0}"
: "${DATA_HOME_CONFIGURE_SYSTEM_MOUNT:=1}"
: "${DATA_HOME_SYSTEM_MOUNT_POINT:=}"
: "${DATA_HOME_SPLIT_VOLUMES:=1}"
: "${DATA_HOME_VOLUME_PREFIX:=${DATA_DISK_USER_DATA_NAME}}"
: "${DATA_HOME_USERS:=}"
: "${DATA_HOME_SUBVOLUME_FSTAB:=1}"
: "${DATA_HOME_SUBVOLUME_MOUNT_OPTS:=rw,nobrowse}"
: "${MANAGED_PATHS_FIX_PERMISSIONS:=1}"
: "${MANAGED_PATHS_STRIP_ACL:=1}"
: "${MANAGED_PATHS_CLEAR_QUARANTINE:=1}"
: "${MANAGED_PATHS_STRIP_XATTRS:=0}"
: "${MANAGED_HOME_DIR_MODE:=700}"
: "${BUILD_CHAINS_BIND_M2_TO_HOME:=1}"
: "${BUILD_CHAINS_M2_SOURCE_DIR:=m2}"
: "${BUILD_CHAINS_M2_HOME_PATH:=.m2}"
: "${BUILD_CHAINS_SPLIT_VOLUMES:=1}"
: "${BUILD_CHAINS_VOLUME_PREFIX:=${DATA_DISK_BUILD_CHAINS_NAME}}"
: "${BUILD_CHAINS_SUBVOLUME_SPECS:=java:.m2 nodejs:.npm cache:.cache go:go}"
: "${BUILD_CHAINS_SUBVOLUME_FSTAB:=1}"
: "${BUILD_CHAINS_SUBVOLUME_MOUNT_OPTS:=rw,nobrowse}"
: "${LIB_CACHES_SPLIT_VOLUMES:=1}"
: "${LIB_CACHES_DEDICATED_VOLUME:=1}"
: "${LIB_CACHES_ROOT_VOLUME_LABEL:=${DATA_DISK_USER_LIBRARY_NAME} Caches}"
: "${LIB_CACHES_ROOT_VOLUME_FSTAB:=1}"
: "${LIB_CACHES_ROOT_VOLUME_MOUNT_OPTS:=rw,nobrowse}"
: "${LIB_CACHES_ROOT_VOLUME_QUOTA_GB:=0}"
: "${LIB_CACHES_ROOT_VOLUME_RESERVE_GB:=0}"
: "${LIB_CACHES_CONTAINER_SOURCE:=user-library}"
: "${LIB_CACHES_VOLUME_PREFIX:=${DATA_DISK_USER_LIBRARY_NAME} Cache}"
: "${LIB_CACHES_BASE_REL_PATH:=Library/Caches}"
: "${LIB_CACHES_SUBVOLUME_SPECS:=jetbrains:JetBrains poetry:pypoetry jdt:.jdt pip:pip gopls:gopls goimports:goimports go:go}"
: "${LIB_CACHES_SUBVOLUME_FSTAB:=1}"
: "${LIB_CACHES_SUBVOLUME_MOUNT_OPTS:=rw,nobrowse}"
: "${LIB_APP_SUPPORT_SPLIT_VOLUMES:=1}"
: "${LIB_APP_SUPPORT_VOLUME_PREFIX:=${DATA_DISK_USER_LIBRARY_NAME} App Support}"
: "${LIB_APP_SUPPORT_BASE_REL_PATH:=Library/Application Support}"
: "${LIB_APP_SUPPORT_SUBVOLUME_SPECS:=jetbrains:JetBrains|code_insiders:Code - Insiders|code:Code|comet:Comet}"
: "${LIB_APP_SUPPORT_SUBVOLUME_FSTAB:=1}"
: "${LIB_APP_SUPPORT_SUBVOLUME_MOUNT_OPTS:=rw,nobrowse}"
: "${VM_IMAGES_SPLIT_VOLUMES:=1}"
: "${VM_IMAGES_VOLUME_PREFIX:=${DATA_DISK_VM_IMAGES_NAME}}"
: "${VM_IMAGES_SUBVOLUME_SPECS:=lima:.lima tart:.tart}" 
: "${VM_IMAGES_SUBVOLUME_FSTAB:=1}"
: "${VM_IMAGES_SUBVOLUME_MOUNT_OPTS:=rw,nobrowse}"
: "${GIT_STORE_CONFIGURE_SYSTEM_MOUNT:=1}"
: "${GIT_STORE_SYSTEM_MOUNT_POINT:=/private/var/lib/git}"
: "${NIX_STORE_CONFIGURE_SYSTEM_MOUNT:=1}"
: "${NIX_STORE_SYSTEM_MOUNT_POINT:=/nix}"
: "${NIX_STORE_CONFIGURE_SYNTHETIC:=1}"
: "${VOLUME_STATUS_ENABLE:=1}"
: "${VOLUME_STATUS_DIR:=/private/var/run/macos-image-template-provision/volumes}"

resolve_data_home_user() {
  local preferred="${DATA_HOME_USER:-}"
  local candidate

  if [[ -n "${preferred}" ]] && dscl . -read "/Users/${preferred}" >/dev/null 2>&1; then
    echo "${preferred}"
    return 0
  fi

  for candidate in "${PACKER_SSH_USERNAME:-}" "${SUDO_USER:-}" "${USER:-}" admin; do
    if [[ -n "${candidate}" ]] && dscl . -read "/Users/${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done

  echo "admin"
}

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

resolve_path_best_effort() {
  local path="$1"
  realpath "${path}" 2>/dev/null || echo "${path}"
}

normalize_managed_path_permissions() {
  local user="$1"
  local path="$2"
  local mode="${3:-}"

  if [[ "${MANAGED_PATHS_FIX_PERMISSIONS}" != "1" ]]; then
    return 0
  fi
  if [[ -z "${user:-}" || -z "${path:-}" || ! -e "${path}" ]]; then
    return 0
  fi

  sudo chown -R "${user}:staff" "${path}" >/dev/null 2>&1 || true
  if [[ "${MANAGED_PATHS_STRIP_ACL}" == "1" ]]; then
    sudo chmod -RN "${path}" >/dev/null 2>&1 || true
  fi
  if [[ "${MANAGED_PATHS_CLEAR_QUARANTINE}" == "1" ]] && command -v xattr >/dev/null 2>&1; then
    sudo xattr -dr com.apple.quarantine "${path}" >/dev/null 2>&1 || true
  fi
  if [[ "${MANAGED_PATHS_STRIP_XATTRS}" == "1" ]] && command -v xattr >/dev/null 2>&1; then
    sudo xattr -cr "${path}" >/dev/null 2>&1 || true
  fi
  sudo chmod -R u+rwX "${path}" >/dev/null 2>&1 || true

  if [[ -n "${mode}" ]]; then
    sudo chmod "${mode}" "${path}" >/dev/null 2>&1 || true
  fi
}

apply_apfs_volume_limits() {
  local vol_ref="$1"
  local quota_gb="$2"
  local reserve_gb="$3"

  if [[ -n "${quota_gb:-}" && "${quota_gb}" != "0" ]]; then
    sudo diskutil apfs setQuota "${vol_ref}" "${quota_gb}g" >/dev/null 2>&1 || true
  fi

  if [[ -n "${reserve_gb:-}" && "${reserve_gb}" != "0" ]]; then
    sudo diskutil apfs setReserve "${vol_ref}" "${reserve_gb}g" >/dev/null 2>&1 || true
  fi
}

volume_mounted_at_target() {
  local vol_ref="$1"
  local target_path="$2"
  local mount_point
  local resolved_mount
  local resolved_target

  mount_point="$(diskutil info -plist "${vol_ref}" | plutil -extract MountPoint raw -o - - 2>/dev/null || true)"
  if [[ -z "${mount_point:-}" ]]; then
    return 1
  fi

  resolved_mount="$(resolve_path_best_effort "${mount_point}")"
  resolved_target="$(resolve_path_best_effort "${target_path}")"

  [[ "${mount_point}" == "${target_path}" || "${resolved_mount}" == "${resolved_target}" ]]
}

volume_status_key() {
  local raw="$1"
  echo "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

record_volume_status() {
  local key="$1"
  local label="$2"
  local target="$3"
  local state="$4" # success|failed|skipped
  local detail="${5:-}"
  local status_file ok_file failed_file skipped_file

  if [[ "${VOLUME_STATUS_ENABLE}" != "1" ]]; then
    return 0
  fi

  key="$(volume_status_key "${key}")"
  [[ -z "${key}" ]] && key="volume"

  sudo install -d -m 0755 "${VOLUME_STATUS_DIR}" >/dev/null 2>&1 || true

  status_file="${VOLUME_STATUS_DIR}/${key}.status"
  ok_file="${VOLUME_STATUS_DIR}/${key}.ok"
  failed_file="${VOLUME_STATUS_DIR}/${key}.failed"
  skipped_file="${VOLUME_STATUS_DIR}/${key}.skipped"

  {
    printf 'timestamp=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'state=%s\n' "${state}"
    printf 'label=%s\n' "${label}"
    printf 'target=%s\n' "${target}"
    printf 'detail=%s\n' "${detail}"
  } | sudo tee "${status_file}" >/dev/null

  sudo rm -f "${ok_file}" "${failed_file}" "${skipped_file}" >/dev/null 2>&1 || true
  case "${state}" in
    success) printf '%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" | sudo tee "${ok_file}" >/dev/null ;;
    failed) printf '%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" | sudo tee "${failed_file}" >/dev/null ;;
    *) printf '%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" | sudo tee "${skipped_file}" >/dev/null ;;
  esac
}

mount_volume_with_seed() {
  local vol_ref="$1"
  local target_path="$2"
  local source_had_content=0
  local seed_copied=0
  local seed_mount=""
  local current_mount=""

  sudo mkdir -p "${target_path}"

  if [[ -d "${target_path}" && -n "$(ls -A "${target_path}" 2>/dev/null || true)" ]]; then
    source_had_content=1
  fi

  sudo diskutil unmount "${vol_ref}" >/dev/null 2>&1 || true

  seed_mount="$(mktemp -d /private/tmp/setup-data-disk-seed.XXXXXX)"
  if ! sudo diskutil mount -mountPoint "${seed_mount}" "${vol_ref}" >/dev/null 2>&1; then
    sudo rmdir "${seed_mount}" >/dev/null 2>&1 || true
    return 1
  fi

  current_mount="$(diskutil info -plist "${vol_ref}" | plutil -extract MountPoint raw -o - - 2>/dev/null || true)"
  if [[ -z "${current_mount:-}" ]]; then
    current_mount="${seed_mount}"
  fi

  if [[ "${source_had_content}" == "1" && -z "$(ls -A "${current_mount}" 2>/dev/null || true)" ]]; then
    if sudo ditto "${target_path}" "${current_mount}"; then
      seed_copied=1
    else
      echo "Warning: failed to seed ${vol_ref} from ${target_path}; continuing without cleanup."
    fi
  fi

  sudo diskutil unmount "${vol_ref}" >/dev/null 2>&1 || true

  if [[ "${seed_copied}" == "1" ]]; then
    sudo find "${target_path}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + >/dev/null 2>&1 || true
  fi

  sudo mkdir -p "${target_path}"
  sudo diskutil mount -mountPoint "${target_path}" "${vol_ref}" >/dev/null 2>&1 || true
  sudo rmdir "${seed_mount}" >/dev/null 2>&1 || true

  volume_mounted_at_target "${vol_ref}" "${target_path}"
}

: "Detect secondary physical disks"
DATA_DISKS=()
while IFS= read -r disk; do
  [[ -n "${disk}" ]] && DATA_DISKS+=("${disk}")
done < <(diskutil list physical | awk '/^\/dev\/disk[0-9]+/ { gsub("/dev/", "", $1); print $1 }' | awk '$1 != "disk0" { print }')

if [[ "${#DATA_DISKS[@]}" -eq 0 ]]; then
  echo 'No secondary disks detected during build, skipping data-disk migration.'
  exit 0
fi

DISK_NAMES=(
  "${DATA_DISK_USER_DATA_NAME}"
  "${DATA_DISK_USER_LIBRARY_NAME}"
  "${DATA_DISK_GIT_STORE_NAME}"
  "${DATA_DISK_NIX_STORE_NAME}"
  "${DATA_DISK_BUILD_CHAINS_NAME}"
  "${DATA_DISK_VM_IMAGES_NAME}"
)

if [[ "${#DATA_DISKS[@]}" -lt "${#DISK_NAMES[@]}" ]]; then
  echo "Warning: found ${#DATA_DISKS[@]} secondary disks but ${#DISK_NAMES[@]} logical data disks requested."
  echo "         Missing roles will be skipped for this run."
fi

USER_DATA_MOUNT_POINT=""
USER_LIBRARY_MOUNT_POINT=""
GIT_STORE_MOUNT_POINT=""
NIX_STORE_MOUNT_POINT=""
BUILD_CHAINS_MOUNT_POINT=""
VM_IMAGES_MOUNT_POINT=""
USER_DATA_VOL_REF=""
USER_LIBRARY_VOL_REF=""
GIT_STORE_VOL_REF=""
NIX_STORE_VOL_REF=""
BUILD_CHAINS_VOL_REF=""
VM_IMAGES_VOL_REF=""

for idx in "${!DISK_NAMES[@]}"; do
  if [[ "$idx" -ge "${#DATA_DISKS[@]}" ]]; then
    break
  fi

  DATA_DISK="${DATA_DISKS[$idx]}"
  DATA_DISK_LABEL="${DISK_NAMES[$idx]}"
  INITIAL_SIZE_GB=0

  case "${DATA_DISK_LABEL}" in
    "${DATA_DISK_USER_DATA_NAME}") INITIAL_SIZE_GB="${USER_DATA_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_USER_LIBRARY_NAME}") INITIAL_SIZE_GB="${USER_LIBRARY_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_GIT_STORE_NAME}") INITIAL_SIZE_GB="${GIT_STORE_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_NIX_STORE_NAME}") INITIAL_SIZE_GB="${NIX_STORE_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_BUILD_CHAINS_NAME}") INITIAL_SIZE_GB="${BUILD_CHAINS_DISK_INITIAL_SIZE_GB}" ;;
    "${DATA_DISK_VM_IMAGES_NAME}") INITIAL_SIZE_GB="${VM_IMAGES_DISK_INITIAL_SIZE_GB}" ;;
  esac

  echo "Assigning /dev/${DATA_DISK} to '${DATA_DISK_LABEL}'"

  if ! diskutil info "${DATA_DISK_LABEL}" >/dev/null 2>&1; then
    sudo diskutil unmountDisk force "/dev/${DATA_DISK}" >/dev/null 2>&1 || true

    if ! sudo diskutil eraseDisk APFS "${DATA_DISK_LABEL}" GPT "/dev/${DATA_DISK}"; then
      echo "First erase attempt failed for ${DATA_DISK_LABEL}, retrying after force unmount..."
      sudo diskutil unmountDisk force "/dev/${DATA_DISK}" >/dev/null 2>&1 || true
      sleep 2

      if ! sudo diskutil eraseDisk APFS "${DATA_DISK_LABEL}" GPT "/dev/${DATA_DISK}"; then
        echo "Erase failed twice; attempting to use an existing APFS volume on /dev/${DATA_DISK}."

        EXISTING_VOL="$(diskutil list "/dev/${DATA_DISK}" | awk '/Apple_APFS/ {print $NF; exit}' || true)"
        if [[ -n "${EXISTING_VOL:-}" ]]; then
          sudo diskutil rename "${EXISTING_VOL}" "${DATA_DISK_LABEL}" || true
        else
          EXISTING_CONTAINER="$(diskutil list "/dev/${DATA_DISK}" | awk '/APFS Container Scheme/ {print $NF; exit}' || true)"
          if [[ -n "${EXISTING_CONTAINER:-}" ]]; then
            echo "Found APFS container ${EXISTING_CONTAINER} without a volume; creating '${DATA_DISK_LABEL}'."
            sudo diskutil apfs addVolume "${EXISTING_CONTAINER}" APFS "${DATA_DISK_LABEL}" || true
          fi
        fi

        if ! diskutil info "${DATA_DISK_LABEL}" >/dev/null 2>&1; then
          echo "Unable to prepare ${DATA_DISK_LABEL} on /dev/${DATA_DISK}." >&2
          continue
        fi
      fi
    fi
  fi

  DATA_VOL_REF="${DATA_DISK_LABEL}"
  if ! diskutil info "${DATA_VOL_REF}" >/dev/null 2>&1; then
    DATA_VOL_REF="$(diskutil list "/dev/${DATA_DISK}" | awk '/Apple_APFS/ {print $NF; exit}' || true)"
  fi
  if [[ -z "${DATA_VOL_REF:-}" ]]; then
    EXISTING_CONTAINER="$(diskutil list "/dev/${DATA_DISK}" | awk '/APFS Container Scheme/ {print $NF; exit}' || true)"
    if [[ -n "${EXISTING_CONTAINER:-}" ]]; then
      echo "No APFS volume found on ${EXISTING_CONTAINER}; creating '${DATA_DISK_LABEL}'."
      sudo diskutil apfs addVolume "${EXISTING_CONTAINER}" APFS "${DATA_DISK_LABEL}" || true
      DATA_VOL_REF="$(diskutil list "/dev/${DATA_DISK}" | awk '/Apple_APFS/ {print $NF; exit}' || true)"
    fi
  fi
  if [[ -z "${DATA_VOL_REF:-}" ]]; then
    echo "Warning: unable to determine APFS volume for /dev/${DATA_DISK}; skipping role '${DATA_DISK_LABEL}'."
    continue
  fi

  if [[ "$INITIAL_SIZE_GB" -gt 0 ]]; then
    DATA_CONTAINER_DEV=$(diskutil info -plist "${DATA_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
    if [[ -z "${DATA_CONTAINER_DEV:-}" ]]; then
      DATA_CONTAINER_DEV=$(diskutil info "${DATA_VOL_REF}" | awk -F': *' '/APFS Container Reference/ {print $2; exit}' || true)
    fi
    CURRENT_BYTES=$(diskutil info -plist "${DATA_VOL_REF}" | plutil -extract TotalSize raw -o - - 2>/dev/null || echo 0)
    TARGET_BYTES=$(( INITIAL_SIZE_GB * 1024 * 1024 * 1024 ))

    if [[ "$TARGET_BYTES" -ne "$CURRENT_BYTES" ]]; then
      if [[ -n "${DATA_CONTAINER_DEV:-}" ]]; then
        if ! sudo diskutil apfs resizeContainer "$DATA_CONTAINER_DEV" "${INITIAL_SIZE_GB}g"; then
          echo "Warning: resize to ${INITIAL_SIZE_GB}G failed for ${DATA_DISK_LABEL} (${DATA_CONTAINER_DEV}); continuing."
        fi
      else
        echo "Warning: could not resolve APFS container for ${DATA_VOL_REF}; skipping resize."
      fi
    else
      echo "Skipping ${DATA_DISK_LABEL} resize: target (${INITIAL_SIZE_GB}G) already matches current size."
    fi
  fi

  sudo diskutil mount "${DATA_VOL_REF}" || true
  DATA_MOUNT_POINT="$(diskutil info -plist "${DATA_VOL_REF}" | plutil -extract MountPoint raw -o - - 2>/dev/null || true)"
  if [[ -z "${DATA_MOUNT_POINT:-}" ]]; then
    DATA_MOUNT_POINT="/Volumes/${DATA_VOL_REF}"
  fi
  sudo mkdir -p "${DATA_MOUNT_POINT}"

  if [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_USER_DATA_NAME}" ]]; then
    USER_DATA_MOUNT_POINT="${DATA_MOUNT_POINT}"
    USER_DATA_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_USER_LIBRARY_NAME}" ]]; then
    USER_LIBRARY_MOUNT_POINT="${DATA_MOUNT_POINT}"
    USER_LIBRARY_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_GIT_STORE_NAME}" ]]; then
    GIT_STORE_MOUNT_POINT="${DATA_MOUNT_POINT}"
    GIT_STORE_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_NIX_STORE_NAME}" ]]; then
    NIX_STORE_MOUNT_POINT="${DATA_MOUNT_POINT}"
    NIX_STORE_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_BUILD_CHAINS_NAME}" ]]; then
    BUILD_CHAINS_MOUNT_POINT="${DATA_MOUNT_POINT}"
    BUILD_CHAINS_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_VM_IMAGES_NAME}" ]]; then
    VM_IMAGES_MOUNT_POINT="${DATA_MOUNT_POINT}"
    VM_IMAGES_VOL_REF="${DATA_VOL_REF}"
  fi
done

: "Optionally mount dedicated Nix Store volume to a stable system path (default: /nix)"
if [[ "${NIX_STORE_CONFIGURE_SYSTEM_MOUNT}" == "1" ]]; then
  if [[ -n "${NIX_STORE_VOL_REF:-}" ]]; then
    NIX_VOLUME_UUID="$(diskutil info -plist "${NIX_STORE_VOL_REF}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
    if [[ -z "${NIX_VOLUME_UUID:-}" ]]; then
      echo "Warning: unable to resolve VolumeUUID for ${NIX_STORE_VOL_REF}; skipping persistent ${NIX_STORE_SYSTEM_MOUNT_POINT} mount setup."
    else
      if [[ "${NIX_STORE_CONFIGURE_SYNTHETIC}" == "1" && "${NIX_STORE_SYSTEM_MOUNT_POINT}" == /* ]]; then
        SYNTHETIC_LEAF="${NIX_STORE_SYSTEM_MOUNT_POINT#/}"
        if [[ -n "${SYNTHETIC_LEAF}" && "${SYNTHETIC_LEAF}" != *"/"* ]]; then
          if ! grep -Eq "^${SYNTHETIC_LEAF}([[:space:]]|$)" /etc/synthetic.conf 2>/dev/null; then
            printf '%s\n' "${SYNTHETIC_LEAF}" | sudo tee -a /etc/synthetic.conf >/dev/null
            echo "Added '${SYNTHETIC_LEAF}' to /etc/synthetic.conf for persistent root mountpoint support."
            echo "Note: synthetic entries are applied at boot; reboot may be required for full effect."
          fi
        fi
      fi

      NIX_CAN_MOUNT_NOW=1
      if ! sudo mkdir -p "${NIX_STORE_SYSTEM_MOUNT_POINT}"; then
        echo "Warning: could not create ${NIX_STORE_SYSTEM_MOUNT_POINT} now (likely read-only root before reboot)."
        echo "         Keeping /etc/fstab entry and deferring live mount until after reboot."
        NIX_CAN_MOUNT_NOW=0
      fi

      FSTAB_PREFIX="UUID=${NIX_VOLUME_UUID} ${NIX_STORE_SYSTEM_MOUNT_POINT} apfs"
      FSTAB_LINE="${FSTAB_PREFIX} rw,nobrowse"
      if ! grep -Fq "${FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
        printf '%s\n' "${FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
      fi

      if [[ "${NIX_CAN_MOUNT_NOW}" == "1" ]]; then
        if ! volume_mounted_at_target "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}"; then
          sudo diskutil unmount "${NIX_STORE_VOL_REF}" >/dev/null 2>&1 || true
          sudo diskutil mount -mountPoint "${NIX_STORE_SYSTEM_MOUNT_POINT}" "${NIX_STORE_VOL_REF}" || true
        fi

        if volume_mounted_at_target "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}"; then
          echo "Nix Store mounted at ${NIX_STORE_SYSTEM_MOUNT_POINT} using volume ${NIX_STORE_VOL_REF} (${NIX_VOLUME_UUID})."
          record_volume_status "nix-store" "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}" "success" "mounted"
        else
          echo "Warning: could not mount ${NIX_STORE_VOL_REF} at ${NIX_STORE_SYSTEM_MOUNT_POINT}; verify /etc/fstab and retry after reboot."
          record_volume_status "nix-store" "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}" "failed" "mount-failed"
        fi
      else
        echo "Info: deferred live mount for ${NIX_STORE_VOL_REF}; reboot will apply synthetic root + fstab mount path ${NIX_STORE_SYSTEM_MOUNT_POINT}."
        record_volume_status "nix-store" "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}" "skipped" "deferred-until-reboot"
      fi
    fi
  else
    echo "Warning: Nix Store volume ref not detected; skipping ${NIX_STORE_SYSTEM_MOUNT_POINT} mount setup."
    record_volume_status "nix-store" "Nix Store" "${NIX_STORE_SYSTEM_MOUNT_POINT}" "skipped" "volume-ref-missing"
  fi
fi

: "Optionally mount dedicated Git Store volume to a stable system path"
if [[ "${GIT_STORE_CONFIGURE_SYSTEM_MOUNT}" == "1" ]]; then
  if [[ -n "${GIT_STORE_VOL_REF:-}" ]]; then
    GIT_VOLUME_UUID="$(diskutil info -plist "${GIT_STORE_VOL_REF}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
    if [[ -z "${GIT_VOLUME_UUID:-}" ]]; then
      echo "Warning: unable to resolve VolumeUUID for ${GIT_STORE_VOL_REF}; skipping persistent ${GIT_STORE_SYSTEM_MOUNT_POINT} mount setup."
    else
      sudo mkdir -p "${GIT_STORE_SYSTEM_MOUNT_POINT}"

      GIT_FSTAB_PREFIX="UUID=${GIT_VOLUME_UUID} ${GIT_STORE_SYSTEM_MOUNT_POINT} apfs"
      GIT_FSTAB_LINE="${GIT_FSTAB_PREFIX} rw,nobrowse"
      if ! grep -Fq "${GIT_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
        printf '%s\n' "${GIT_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
      fi

      if ! volume_mounted_at_target "${GIT_STORE_VOL_REF}" "${GIT_STORE_SYSTEM_MOUNT_POINT}"; then
        sudo diskutil unmount "${GIT_STORE_VOL_REF}" >/dev/null 2>&1 || true
        sudo diskutil mount -mountPoint "${GIT_STORE_SYSTEM_MOUNT_POINT}" "${GIT_STORE_VOL_REF}" || true
      fi

      if volume_mounted_at_target "${GIT_STORE_VOL_REF}" "${GIT_STORE_SYSTEM_MOUNT_POINT}"; then
        echo "Git Store mounted at ${GIT_STORE_SYSTEM_MOUNT_POINT} using volume ${GIT_STORE_VOL_REF} (${GIT_VOLUME_UUID})."
        record_volume_status "git-store" "${GIT_STORE_VOL_REF}" "${GIT_STORE_SYSTEM_MOUNT_POINT}" "success" "mounted"
      else
        echo "Warning: could not mount ${GIT_STORE_VOL_REF} at ${GIT_STORE_SYSTEM_MOUNT_POINT}; verify /etc/fstab and retry after reboot."
        record_volume_status "git-store" "${GIT_STORE_VOL_REF}" "${GIT_STORE_SYSTEM_MOUNT_POINT}" "failed" "mount-failed"
      fi
    fi
  else
    echo "Warning: Git Store volume ref not detected; skipping ${GIT_STORE_SYSTEM_MOUNT_POINT} mount setup."
    record_volume_status "git-store" "Git Store" "${GIT_STORE_SYSTEM_MOUNT_POINT}" "skipped" "volume-ref-missing"
  fi
fi

DATA_MOUNT_POINT="${USER_DATA_MOUNT_POINT}"
if [[ -z "${DATA_MOUNT_POINT:-}" ]]; then
  echo "Warning: '${DATA_DISK_USER_DATA_NAME}' mountpoint not detected; falling back to /Volumes/${DATA_DISK_USER_DATA_NAME}."
  DATA_MOUNT_POINT="/Volumes/${DATA_DISK_USER_DATA_NAME}"
  sudo mkdir -p "${DATA_MOUNT_POINT}"
fi

: "Relocate /Users to data volume"
USERS_RELOCATED=0
HOME_MOUNTED_FROM_USER_DATA=0
DATA_HOME_USER="$(resolve_data_home_user)"
ACTUAL_HOME_DIR="$(resolve_home_dir_for_user "${DATA_HOME_USER}")"

if [[ -z "${DATA_HOME_SYSTEM_MOUNT_POINT:-}" ]]; then
  DATA_HOME_SYSTEM_MOUNT_POINT="${ACTUAL_HOME_DIR}"
fi
if [[ -z "${DATA_HOME_USERS:-}" ]]; then
  DATA_HOME_USERS="${DATA_HOME_USER}"
fi

: "Optionally mount dedicated User Data volume directly at the primary user home path"
if [[ "${DATA_HOME_CONFIGURE_SYSTEM_MOUNT}" == "1" ]]; then
  if [[ -n "${USER_DATA_VOL_REF:-}" ]]; then
    if [[ "${DATA_HOME_SPLIT_VOLUMES}" == "1" ]]; then
      USER_DATA_CONTAINER_REF="$(diskutil info -plist "${USER_DATA_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)"
      if [[ -z "${USER_DATA_CONTAINER_REF:-}" ]]; then
        echo "Warning: unable to resolve APFS container for ${USER_DATA_VOL_REF}; skipping user-home split volumes."
      else
        for home_user in ${DATA_HOME_USERS}; do
          if ! dscl . -read "/Users/${home_user}" >/dev/null 2>&1; then
            echo "Warning: user '${home_user}' does not exist; skipping User Data subvolume setup."
            record_volume_status "user-home-${home_user}" "${DATA_HOME_VOLUME_PREFIX} ${home_user}" "/Users/${home_user}" "skipped" "user-missing"
            continue
          fi

          HOME_TARGET_PATH="$(resolve_home_dir_for_user "${home_user}")"
          HOME_VOLUME_LABEL="${DATA_HOME_VOLUME_PREFIX} ${home_user}"

          if ! diskutil info "${HOME_VOLUME_LABEL}" >/dev/null 2>&1; then
            echo "Creating APFS home subvolume '${HOME_VOLUME_LABEL}' in ${USER_DATA_CONTAINER_REF}"
            sudo diskutil apfs addVolume "${USER_DATA_CONTAINER_REF}" APFS "${HOME_VOLUME_LABEL}" || true
          fi

          if ! diskutil info "${HOME_VOLUME_LABEL}" >/dev/null 2>&1; then
            echo "Warning: could not resolve home subvolume '${HOME_VOLUME_LABEL}'; skipping ${HOME_TARGET_PATH}."
            record_volume_status "user-home-${home_user}" "${HOME_VOLUME_LABEL}" "${HOME_TARGET_PATH}" "failed" "volume-missing"
            continue
          fi

          HOME_VOLUME_UUID="$(diskutil info -plist "${HOME_VOLUME_LABEL}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
          if [[ -z "${HOME_VOLUME_UUID:-}" ]]; then
            echo "Warning: unable to resolve VolumeUUID for ${HOME_VOLUME_LABEL}; skipping ${HOME_TARGET_PATH}."
            record_volume_status "user-home-${home_user}" "${HOME_VOLUME_LABEL}" "${HOME_TARGET_PATH}" "failed" "uuid-missing"
            continue
          fi

          sudo mkdir -p "${HOME_TARGET_PATH}"

          if [[ "${DATA_HOME_SUBVOLUME_FSTAB}" == "1" ]]; then
            HOME_FSTAB_PREFIX="UUID=${HOME_VOLUME_UUID} ${HOME_TARGET_PATH} apfs"
            HOME_FSTAB_LINE="${HOME_FSTAB_PREFIX} ${DATA_HOME_SUBVOLUME_MOUNT_OPTS}"
            if ! grep -Fq "${HOME_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
              printf '%s\n' "${HOME_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
            fi
          fi

          if mount_volume_with_seed "${HOME_VOLUME_LABEL}" "${HOME_TARGET_PATH}"; then
            normalize_managed_path_permissions "${home_user}" "${HOME_TARGET_PATH}" "${MANAGED_HOME_DIR_MODE}"
            echo "Mounted ${HOME_VOLUME_LABEL} at ${HOME_TARGET_PATH}"
            record_volume_status "user-home-${home_user}" "${HOME_VOLUME_LABEL}" "${HOME_TARGET_PATH}" "success" "mounted"
            if [[ "${home_user}" == "${DATA_HOME_USER}" ]]; then
              HOME_MOUNTED_FROM_USER_DATA=1
            fi
          else
            echo "Warning: failed to mount ${HOME_VOLUME_LABEL} at ${HOME_TARGET_PATH}."
            record_volume_status "user-home-${home_user}" "${HOME_VOLUME_LABEL}" "${HOME_TARGET_PATH}" "failed" "mount-failed"
          fi
        done
      fi
    else
      DATA_HOME_VOLUME_UUID="$(diskutil info -plist "${USER_DATA_VOL_REF}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
      if [[ -z "${DATA_HOME_VOLUME_UUID:-}" ]]; then
        echo "Warning: unable to resolve VolumeUUID for ${USER_DATA_VOL_REF}; skipping persistent ${DATA_HOME_SYSTEM_MOUNT_POINT} mount setup."
      else
        if [[ -d "${ACTUAL_HOME_DIR}" ]]; then
          if [[ -z "$(ls -A "${DATA_MOUNT_POINT}" 2>/dev/null || true)" ]]; then
            if ! sudo ditto "${ACTUAL_HOME_DIR}" "${DATA_MOUNT_POINT}"; then
              echo "Warning: initial home copy to ${DATA_MOUNT_POINT} failed; continuing with best effort."
            fi
          fi
        fi

        sudo mkdir -p "${DATA_HOME_SYSTEM_MOUNT_POINT}"

        DATA_HOME_FSTAB_PREFIX="UUID=${DATA_HOME_VOLUME_UUID} ${DATA_HOME_SYSTEM_MOUNT_POINT} apfs"
        DATA_HOME_FSTAB_LINE="${DATA_HOME_FSTAB_PREFIX} rw,nobrowse"
        if ! grep -Fq "${DATA_HOME_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
          printf '%s\n' "${DATA_HOME_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
        fi

        if ! volume_mounted_at_target "${USER_DATA_VOL_REF}" "${DATA_HOME_SYSTEM_MOUNT_POINT}"; then
          sudo diskutil unmount "${USER_DATA_VOL_REF}" >/dev/null 2>&1 || true
          sudo diskutil mount -mountPoint "${DATA_HOME_SYSTEM_MOUNT_POINT}" "${USER_DATA_VOL_REF}" || true
        fi

        if volume_mounted_at_target "${USER_DATA_VOL_REF}" "${DATA_HOME_SYSTEM_MOUNT_POINT}"; then
          normalize_managed_path_permissions "${DATA_HOME_USER}" "${DATA_HOME_SYSTEM_MOUNT_POINT}" "${MANAGED_HOME_DIR_MODE}"
          HOME_MOUNTED_FROM_USER_DATA=1
          echo "User home mounted at ${DATA_HOME_SYSTEM_MOUNT_POINT} using volume ${USER_DATA_VOL_REF} (${DATA_HOME_VOLUME_UUID})."
        else
          echo "Warning: could not mount ${USER_DATA_VOL_REF} at ${DATA_HOME_SYSTEM_MOUNT_POINT}; keeping fallback copy workflow."
        fi
      fi
    fi
  else
    echo "Warning: User Data volume ref not detected; skipping user-home mount setup."
  fi
fi

if [[ "${DATA_RELOCATE_USERS_ROOT}" == "1" && ! -L /Users ]]; then
  sudo mkdir -p "${DATA_MOUNT_POINT}/Users"
  if ! sudo ditto /Users "${DATA_MOUNT_POINT}/Users"; then
    echo "Warning: ditto could not copy all files from /Users (likely protected container metadata)."
    echo "Retrying best-effort copy with rsync and known metadata exclusions..."
    if command -v rsync >/dev/null 2>&1; then
      sudo rsync -a --ignore-errors \
        --exclude='*/.com.apple.containermanagerd.metadata.plist' \
        /Users/ "${DATA_MOUNT_POINT}/Users/" || true
    fi
  fi

  # On some macOS layouts, replacing /Users from a running system is not permitted.
  if sudo mv /Users /private/var/Users.local 2>/dev/null; then
    if sudo ln -s "${DATA_MOUNT_POINT}/Users" /Users; then
      USERS_RELOCATED=1
    else
      echo "Warning: failed to create /Users symlink; restoring original /Users."
      sudo mv /private/var/Users.local /Users || true
    fi
  else
    echo "Warning: unable to move /Users (likely read-only/protected root path). Skipping /Users symlink cutover."
  fi
fi

: "Fallback: copy full user home to data volume"
if [[ "${USERS_RELOCATED}" -eq 0 && "${HOME_MOUNTED_FROM_USER_DATA}" -eq 0 ]]; then
  USER_HOME="${ACTUAL_HOME_DIR}"
  DATA_USER_HOME="${DATA_MOUNT_POINT}/${DATA_HOME_PARENT_DIR}/${DATA_HOME_USER}"

  if [[ -d "${USER_HOME}" ]]; then
    sudo mkdir -p "${DATA_USER_HOME}"

    if ! sudo ditto "${USER_HOME}" "${DATA_USER_HOME}"; then
      echo "Warning: ditto could not copy full ${USER_HOME}; trying rsync best-effort."
      if command -v rsync >/dev/null 2>&1; then
        sudo rsync -a --ignore-errors \
          --exclude='*/.com.apple.containermanagerd.metadata.plist' \
          "${USER_HOME}/" "${DATA_USER_HOME}/" || true
      fi
    fi

    echo "Home copy complete (fallback mode): ${USER_HOME} -> ${DATA_USER_HOME}"
    echo "NOTE: To switch account home safely, update NFSHomeDirectory and reboot before deleting ${USER_HOME}."
    echo "      Example: sudo dscl . -create /Users/${DATA_HOME_USER} NFSHomeDirectory '${DATA_USER_HOME}'"
    echo "      Verify after reboot with: dscl . -read /Users/${DATA_HOME_USER} NFSHomeDirectory && echo \"\$HOME\""
  else
    echo "Warning: user home ${USER_HOME} not found; skipping sub-level relocation."
  fi
elif [[ "${HOME_MOUNTED_FROM_USER_DATA}" -eq 1 ]]; then
  echo "Skipping fallback home copy: ${ACTUAL_HOME_DIR} is mounted from ${DATA_DISK_USER_DATA_NAME}."
fi

: "Ensure /private/var/lib exists as a real directory (no symlink relocation)"
if [[ -L /private/var/lib ]]; then
  echo "Warning: legacy symlink detected at /private/var/lib."
  echo "         This script no longer creates /private/var/lib symlinks; using direct mount points where possible."
  echo "         Consider migrating back to a real directory before next rebuild."
elif [[ ! -d /private/var/lib ]]; then
  sudo mkdir -p /private/var/lib
fi

: "Prepare dedicated role data copies (best-effort)"
if [[ -n "${USER_LIBRARY_MOUNT_POINT:-}" && "${DATA_COPY_USER_LIBRARY}" == "1" ]]; then
  SRC_LIBRARY="${ACTUAL_HOME_DIR}/Library"
  DST_LIBRARY="${USER_LIBRARY_MOUNT_POINT}/Users/${DATA_HOME_USER}/Library"
  if [[ -d "${SRC_LIBRARY}" ]]; then
    sudo mkdir -p "${DST_LIBRARY}"
    sudo ditto "${SRC_LIBRARY}" "${DST_LIBRARY}" || true
    echo "User Library copy complete (best-effort): ${SRC_LIBRARY} -> ${DST_LIBRARY}"
    echo "NOTE: To use dedicated user-library disk, switch NFSHomeDirectory to this disk path after reboot workflow."
  fi
fi

if [[ -n "${GIT_STORE_MOUNT_POINT:-}" && "${DATA_COPY_GIT_STORE}" == "1" ]]; then
  SRC_GIT_STORE="${ACTUAL_HOME_DIR}/Git Store"
  DST_GIT_STORE="${GIT_STORE_MOUNT_POINT}/Git Store"
  if [[ -d "${SRC_GIT_STORE}" ]]; then
    sudo mkdir -p "${DST_GIT_STORE}"
    sudo ditto "${SRC_GIT_STORE}" "${DST_GIT_STORE}" || true
    echo "Git Store copy complete (best-effort): ${SRC_GIT_STORE} -> ${DST_GIT_STORE}"
  fi
fi

if [[ -n "${NIX_STORE_MOUNT_POINT:-}" && "${DATA_COPY_NIX_STORE}" == "1" ]]; then
  SRC_NIX_STORE="/nix"
  DST_NIX_STORE="${NIX_STORE_MOUNT_POINT}/nix"
  if [[ -d "${SRC_NIX_STORE}" ]]; then
    sudo mkdir -p "${DST_NIX_STORE}"
    sudo rsync -a --ignore-errors "${SRC_NIX_STORE}/" "${DST_NIX_STORE}/" || true
    echo "Nix store copy complete (best-effort): ${SRC_NIX_STORE} -> ${DST_NIX_STORE}"
    echo "NOTE: Using dedicated Nix disk as live /nix requires additional nix-darwin/Nix setup."
  fi
fi

if [[ -n "${BUILD_CHAINS_MOUNT_POINT:-}" && "${DATA_COPY_BUILD_CHAINS}" == "1" ]]; then
  DEST_BASE="${BUILD_CHAINS_MOUNT_POINT}/Users/${DATA_HOME_USER}/build-chains"
  sudo mkdir -p "${DEST_BASE}"

  for chain_dir in "go" ".m2" ".npm" ".cache"; do
    SRC_PATH="${ACTUAL_HOME_DIR}/${chain_dir}"
    DST_PATH="${DEST_BASE}/${chain_dir}"
    if [[ -d "${SRC_PATH}" ]]; then
      sudo mkdir -p "${DST_PATH}"
      sudo ditto "${SRC_PATH}" "${DST_PATH}" || true
      echo "Build chain copy complete (best-effort): ${SRC_PATH} -> ${DST_PATH}"
      echo "NOTE: switch ${SRC_PATH} to ${DST_PATH} via symlink after reboot validation if desired."
    fi
  done
fi

: "Optionally split Build Chains into dedicated APFS volumes mounted into the primary user's home"
if [[ "${BUILD_CHAINS_SPLIT_VOLUMES}" == "1" && -n "${BUILD_CHAINS_VOL_REF:-}" ]]; then
  BUILD_CHAINS_CONTAINER_REF="$(diskutil info -plist "${BUILD_CHAINS_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)"
  if [[ -z "${BUILD_CHAINS_CONTAINER_REF:-}" ]]; then
    echo "Warning: unable to resolve APFS container for ${BUILD_CHAINS_VOL_REF}; skipping split build-chain volumes."
  else
    for spec in ${BUILD_CHAINS_SUBVOLUME_SPECS}; do
      CHAIN_NAME="${spec%%:*}"
      CHAIN_HOME_REL_PATH="${spec#*:}"
      CHAIN_HOME_PATH="${ACTUAL_HOME_DIR}/${CHAIN_HOME_REL_PATH}"
      CHAIN_VOLUME_LABEL="${BUILD_CHAINS_VOLUME_PREFIX} ${CHAIN_NAME}"

      if ! diskutil info "${CHAIN_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Creating APFS subvolume '${CHAIN_VOLUME_LABEL}' in ${BUILD_CHAINS_CONTAINER_REF}"
        sudo diskutil apfs addVolume "${BUILD_CHAINS_CONTAINER_REF}" APFS "${CHAIN_VOLUME_LABEL}" || true
      fi

      if ! diskutil info "${CHAIN_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Warning: could not resolve subvolume '${CHAIN_VOLUME_LABEL}'; skipping ${CHAIN_HOME_PATH}."
        continue
      fi

      CHAIN_VOLUME_UUID="$(diskutil info -plist "${CHAIN_VOLUME_LABEL}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
      if [[ -z "${CHAIN_VOLUME_UUID:-}" ]]; then
        echo "Warning: could not get VolumeUUID for '${CHAIN_VOLUME_LABEL}'; skipping ${CHAIN_HOME_PATH}."
        continue
      fi

      PREVIOUS_LINK_TARGET=""
      if [[ -L "${CHAIN_HOME_PATH}" ]]; then
        PREVIOUS_LINK_TARGET="$(readlink "${CHAIN_HOME_PATH}" || true)"
        sudo rm -f "${CHAIN_HOME_PATH}"
      fi
      sudo mkdir -p "${CHAIN_HOME_PATH}"

      if [[ -n "${PREVIOUS_LINK_TARGET:-}" && -d "${PREVIOUS_LINK_TARGET}" && -z "$(ls -A "${CHAIN_HOME_PATH}" 2>/dev/null || true)" ]]; then
        sudo ditto "${PREVIOUS_LINK_TARGET}" "${CHAIN_HOME_PATH}" || true
      fi

      if [[ "${BUILD_CHAINS_SUBVOLUME_FSTAB}" == "1" ]]; then
        CHAIN_FSTAB_PREFIX="UUID=${CHAIN_VOLUME_UUID} ${CHAIN_HOME_PATH} apfs"
        CHAIN_FSTAB_LINE="${CHAIN_FSTAB_PREFIX} ${BUILD_CHAINS_SUBVOLUME_MOUNT_OPTS}"
        if ! grep -Fq "${CHAIN_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
          printf '%s\n' "${CHAIN_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
        fi
      fi

      if mount_volume_with_seed "${CHAIN_VOLUME_LABEL}" "${CHAIN_HOME_PATH}"; then
        normalize_managed_path_permissions "${DATA_HOME_USER}" "${CHAIN_HOME_PATH}"
        echo "Mounted ${CHAIN_VOLUME_LABEL} at ${CHAIN_HOME_PATH}"
        record_volume_status "build-chain-${CHAIN_NAME}" "${CHAIN_VOLUME_LABEL}" "${CHAIN_HOME_PATH}" "success" "mounted"
      else
        echo "Warning: failed to mount ${CHAIN_VOLUME_LABEL} at ${CHAIN_HOME_PATH}."
        record_volume_status "build-chain-${CHAIN_NAME}" "${CHAIN_VOLUME_LABEL}" "${CHAIN_HOME_PATH}" "failed" "mount-failed"
      fi
    done
  fi
fi

: "Optionally map ~/.m2 to Build Chains data (user-scoped, no cross-user sharing)"
if [[ "${BUILD_CHAINS_BIND_M2_TO_HOME}" == "1" && "${BUILD_CHAINS_SPLIT_VOLUMES}" != "1" && -n "${BUILD_CHAINS_VOL_REF:-}" ]]; then
  M2_SOURCE_PATH="${BUILD_CHAINS_MOUNT_POINT}/${BUILD_CHAINS_M2_SOURCE_DIR}"
  M2_HOME_PATH="${ACTUAL_HOME_DIR}/${BUILD_CHAINS_M2_HOME_PATH}"

  sudo mkdir -p "${M2_SOURCE_PATH}"

  if [[ -d "${M2_HOME_PATH}" && ! -L "${M2_HOME_PATH}" ]]; then
    sudo ditto "${M2_HOME_PATH}" "${M2_SOURCE_PATH}" || true
    sudo mv "${M2_HOME_PATH}" "${M2_HOME_PATH}.local.$(date +%s)" || true
  fi

  if [[ -L "${M2_HOME_PATH}" ]]; then
    EXISTING_M2_LINK="$(readlink "${M2_HOME_PATH}" || true)"
    if [[ "${EXISTING_M2_LINK}" != "${M2_SOURCE_PATH}" ]]; then
      sudo rm -f "${M2_HOME_PATH}"
    fi
  fi

  if [[ ! -e "${M2_HOME_PATH}" ]]; then
    sudo ln -s "${M2_SOURCE_PATH}" "${M2_HOME_PATH}"
  fi

  sudo chown -h "${DATA_HOME_USER}:staff" "${M2_HOME_PATH}" >/dev/null 2>&1 || true
  sudo chown -R "${DATA_HOME_USER}:staff" "${M2_SOURCE_PATH}" >/dev/null 2>&1 || true
  echo "Mapped ${M2_HOME_PATH} -> ${M2_SOURCE_PATH}"
fi

: "Optionally split VM Images disk into dedicated APFS volumes mounted in the primary user's home"
if [[ "${VM_IMAGES_SPLIT_VOLUMES}" == "1" && -n "${VM_IMAGES_VOL_REF:-}" ]]; then
  VM_IMAGES_CONTAINER_REF="$(diskutil info -plist "${VM_IMAGES_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)"
  if [[ -z "${VM_IMAGES_CONTAINER_REF:-}" ]]; then
    echo "Warning: unable to resolve APFS container for ${VM_IMAGES_VOL_REF}; skipping VM images split volumes."
  else
    for spec in ${VM_IMAGES_SUBVOLUME_SPECS}; do
      VM_STORE_NAME="${spec%%:*}"
      VM_STORE_HOME_REL_PATH="${spec#*:}"
      VM_STORE_HOME_PATH="${ACTUAL_HOME_DIR}/${VM_STORE_HOME_REL_PATH}"
      VM_STORE_VOLUME_LABEL="${VM_IMAGES_VOLUME_PREFIX} ${VM_STORE_NAME}"

      if ! diskutil info "${VM_STORE_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Creating APFS VM store subvolume '${VM_STORE_VOLUME_LABEL}' in ${VM_IMAGES_CONTAINER_REF}"
        sudo diskutil apfs addVolume "${VM_IMAGES_CONTAINER_REF}" APFS "${VM_STORE_VOLUME_LABEL}" || true
      fi

      if ! diskutil info "${VM_STORE_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Warning: could not resolve VM store subvolume '${VM_STORE_VOLUME_LABEL}'; skipping ${VM_STORE_HOME_PATH}."
        continue
      fi

      VM_STORE_VOLUME_UUID="$(diskutil info -plist "${VM_STORE_VOLUME_LABEL}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
      if [[ -z "${VM_STORE_VOLUME_UUID:-}" ]]; then
        echo "Warning: could not get VolumeUUID for '${VM_STORE_VOLUME_LABEL}'; skipping ${VM_STORE_HOME_PATH}."
        continue
      fi

      PREVIOUS_VM_LINK_TARGET=""
      if [[ -L "${VM_STORE_HOME_PATH}" ]]; then
        PREVIOUS_VM_LINK_TARGET="$(readlink "${VM_STORE_HOME_PATH}" || true)"
        sudo rm -f "${VM_STORE_HOME_PATH}"
      fi
      sudo mkdir -p "${VM_STORE_HOME_PATH}"

      if [[ -n "${PREVIOUS_VM_LINK_TARGET:-}" && -d "${PREVIOUS_VM_LINK_TARGET}" && -z "$(ls -A "${VM_STORE_HOME_PATH}" 2>/dev/null || true)" ]]; then
        sudo ditto "${PREVIOUS_VM_LINK_TARGET}" "${VM_STORE_HOME_PATH}" || true
      fi

      if [[ "${VM_IMAGES_SUBVOLUME_FSTAB}" == "1" ]]; then
        VM_STORE_FSTAB_PREFIX="UUID=${VM_STORE_VOLUME_UUID} ${VM_STORE_HOME_PATH} apfs"
        VM_STORE_FSTAB_LINE="${VM_STORE_FSTAB_PREFIX} ${VM_IMAGES_SUBVOLUME_MOUNT_OPTS}"
        if ! grep -Fq "${VM_STORE_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
          printf '%s\n' "${VM_STORE_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
        fi
      fi

      if mount_volume_with_seed "${VM_STORE_VOLUME_LABEL}" "${VM_STORE_HOME_PATH}"; then
        normalize_managed_path_permissions "${DATA_HOME_USER}" "${VM_STORE_HOME_PATH}"
        echo "Mounted ${VM_STORE_VOLUME_LABEL} at ${VM_STORE_HOME_PATH}"
        record_volume_status "vm-store-${VM_STORE_NAME}" "${VM_STORE_VOLUME_LABEL}" "${VM_STORE_HOME_PATH}" "success" "mounted"
      else
        echo "Warning: failed to mount ${VM_STORE_VOLUME_LABEL} at ${VM_STORE_HOME_PATH}."
        record_volume_status "vm-store-${VM_STORE_NAME}" "${VM_STORE_VOLUME_LABEL}" "${VM_STORE_HOME_PATH}" "failed" "mount-failed"
      fi
    done
  fi
fi

: "Library/Caches storage policy: dedicated root volume (default) and optional split subvolumes"
LIB_CACHES_CONTAINER_VOL_REF=""
case "${LIB_CACHES_CONTAINER_SOURCE}" in
  user-library)
    LIB_CACHES_CONTAINER_VOL_REF="${USER_LIBRARY_VOL_REF:-}"
    ;;
  build-chains)
    LIB_CACHES_CONTAINER_VOL_REF="${BUILD_CHAINS_VOL_REF:-}"
    ;;
  *)
    LIB_CACHES_CONTAINER_VOL_REF="${USER_LIBRARY_VOL_REF:-${BUILD_CHAINS_VOL_REF:-}}"
    ;;
esac

if [[ -z "${LIB_CACHES_CONTAINER_VOL_REF:-}" ]]; then
  LIB_CACHES_CONTAINER_VOL_REF="${USER_LIBRARY_VOL_REF:-${BUILD_CHAINS_VOL_REF:-}}"
fi

if [[ -n "${LIB_CACHES_CONTAINER_VOL_REF:-}" ]]; then
  LIB_CACHES_CONTAINER_REF="$(diskutil info -plist "${LIB_CACHES_CONTAINER_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)"
  LIB_CACHES_BASE_PATH="${ACTUAL_HOME_DIR}/${LIB_CACHES_BASE_REL_PATH}"

  if [[ -z "${LIB_CACHES_CONTAINER_REF:-}" ]]; then
    echo "Warning: unable to resolve APFS container for ${LIB_CACHES_CONTAINER_VOL_REF}; skipping Library/Caches volume setup."
  else
    sudo mkdir -p "${LIB_CACHES_BASE_PATH}"

    if [[ "${LIB_CACHES_DEDICATED_VOLUME}" == "1" ]]; then
      if ! diskutil info "${LIB_CACHES_ROOT_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Creating APFS Library/Caches root volume '${LIB_CACHES_ROOT_VOLUME_LABEL}' in ${LIB_CACHES_CONTAINER_REF}"
        sudo diskutil apfs addVolume "${LIB_CACHES_CONTAINER_REF}" APFS "${LIB_CACHES_ROOT_VOLUME_LABEL}" || true
      fi

      if diskutil info "${LIB_CACHES_ROOT_VOLUME_LABEL}" >/dev/null 2>&1; then
        apply_apfs_volume_limits "${LIB_CACHES_ROOT_VOLUME_LABEL}" "${LIB_CACHES_ROOT_VOLUME_QUOTA_GB}" "${LIB_CACHES_ROOT_VOLUME_RESERVE_GB}"

        ROOT_CACHE_UUID="$(diskutil info -plist "${LIB_CACHES_ROOT_VOLUME_LABEL}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
        if [[ -n "${ROOT_CACHE_UUID:-}" && "${LIB_CACHES_ROOT_VOLUME_FSTAB}" == "1" ]]; then
          ROOT_CACHE_FSTAB_PREFIX="UUID=${ROOT_CACHE_UUID} ${LIB_CACHES_BASE_PATH} apfs"
          ROOT_CACHE_FSTAB_LINE="${ROOT_CACHE_FSTAB_PREFIX} ${LIB_CACHES_ROOT_VOLUME_MOUNT_OPTS}"
          if ! grep -Fq "${ROOT_CACHE_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
            printf '%s\n' "${ROOT_CACHE_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
          fi
        fi

        if mount_volume_with_seed "${LIB_CACHES_ROOT_VOLUME_LABEL}" "${LIB_CACHES_BASE_PATH}"; then
          normalize_managed_path_permissions "${DATA_HOME_USER}" "${LIB_CACHES_BASE_PATH}"
          echo "Mounted ${LIB_CACHES_ROOT_VOLUME_LABEL} at ${LIB_CACHES_BASE_PATH}"
          record_volume_status "library-caches-root" "${LIB_CACHES_ROOT_VOLUME_LABEL}" "${LIB_CACHES_BASE_PATH}" "success" "mounted"
        else
          echo "Warning: failed to mount ${LIB_CACHES_ROOT_VOLUME_LABEL} at ${LIB_CACHES_BASE_PATH}."
          record_volume_status "library-caches-root" "${LIB_CACHES_ROOT_VOLUME_LABEL}" "${LIB_CACHES_BASE_PATH}" "failed" "mount-failed"
        fi
      else
        echo "Warning: could not resolve Library/Caches root volume '${LIB_CACHES_ROOT_VOLUME_LABEL}'."
        record_volume_status "library-caches-root" "${LIB_CACHES_ROOT_VOLUME_LABEL}" "${LIB_CACHES_BASE_PATH}" "failed" "volume-missing"
      fi
    fi

    if [[ "${LIB_CACHES_SPLIT_VOLUMES}" == "1" ]]; then
      for spec in ${LIB_CACHES_SUBVOLUME_SPECS}; do
        CACHE_NAME="${spec%%:*}"
        CACHE_REL_PATH="${spec#*:}"
        CACHE_TARGET_PATH="${LIB_CACHES_BASE_PATH}/${CACHE_REL_PATH}"
        CACHE_VOLUME_LABEL="${LIB_CACHES_VOLUME_PREFIX} ${CACHE_NAME}"

        if ! diskutil info "${CACHE_VOLUME_LABEL}" >/dev/null 2>&1; then
          echo "Creating APFS cache subvolume '${CACHE_VOLUME_LABEL}' in ${LIB_CACHES_CONTAINER_REF}"
          sudo diskutil apfs addVolume "${LIB_CACHES_CONTAINER_REF}" APFS "${CACHE_VOLUME_LABEL}" || true
        fi

        if ! diskutil info "${CACHE_VOLUME_LABEL}" >/dev/null 2>&1; then
          echo "Warning: could not resolve cache subvolume '${CACHE_VOLUME_LABEL}'; skipping ${CACHE_TARGET_PATH}."
          continue
        fi

        CACHE_VOLUME_UUID="$(diskutil info -plist "${CACHE_VOLUME_LABEL}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
        if [[ -z "${CACHE_VOLUME_UUID:-}" ]]; then
          echo "Warning: could not get VolumeUUID for '${CACHE_VOLUME_LABEL}'; skipping ${CACHE_TARGET_PATH}."
          continue
        fi

        sudo mkdir -p "${CACHE_TARGET_PATH}"

        if [[ "${LIB_CACHES_SUBVOLUME_FSTAB}" == "1" ]]; then
          CACHE_FSTAB_PREFIX="UUID=${CACHE_VOLUME_UUID} ${CACHE_TARGET_PATH} apfs"
          CACHE_FSTAB_LINE="${CACHE_FSTAB_PREFIX} ${LIB_CACHES_SUBVOLUME_MOUNT_OPTS}"
          if ! grep -Fq "${CACHE_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
            printf '%s\n' "${CACHE_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
          fi
        fi

        if mount_volume_with_seed "${CACHE_VOLUME_LABEL}" "${CACHE_TARGET_PATH}"; then
          normalize_managed_path_permissions "${DATA_HOME_USER}" "${CACHE_TARGET_PATH}"
          echo "Mounted ${CACHE_VOLUME_LABEL} at ${CACHE_TARGET_PATH}"
          record_volume_status "library-cache-${CACHE_NAME}" "${CACHE_VOLUME_LABEL}" "${CACHE_TARGET_PATH}" "success" "mounted"
        else
          echo "Warning: failed to mount ${CACHE_VOLUME_LABEL} at ${CACHE_TARGET_PATH}."
          record_volume_status "library-cache-${CACHE_NAME}" "${CACHE_VOLUME_LABEL}" "${CACHE_TARGET_PATH}" "failed" "mount-failed"
        fi
      done
    fi
  fi
fi

: "Optionally split ~/Library/Application Support into dedicated APFS volumes on User Library container"
if [[ "${LIB_APP_SUPPORT_SPLIT_VOLUMES}" == "1" && -n "${USER_LIBRARY_VOL_REF:-}" ]]; then
  LIB_APP_SUPPORT_CONTAINER_REF="$(diskutil info -plist "${USER_LIBRARY_VOL_REF}" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)"
  LIB_APP_SUPPORT_BASE_PATH="${ACTUAL_HOME_DIR}/${LIB_APP_SUPPORT_BASE_REL_PATH}"

  if [[ -z "${LIB_APP_SUPPORT_CONTAINER_REF:-}" ]]; then
    echo "Warning: unable to resolve APFS container for ${USER_LIBRARY_VOL_REF}; skipping Application Support split volumes."
  else
    sudo mkdir -p "${LIB_APP_SUPPORT_BASE_PATH}"
    IFS='|' read -r -a LIB_APP_SUPPORT_SPECS_ARRAY <<< "${LIB_APP_SUPPORT_SUBVOLUME_SPECS}"

    for spec in "${LIB_APP_SUPPORT_SPECS_ARRAY[@]}"; do
      [[ -z "${spec:-}" ]] && continue

      APP_NAME="${spec%%:*}"
      APP_REL_PATH="${spec#*:}"
      APP_TARGET_PATH="${LIB_APP_SUPPORT_BASE_PATH}/${APP_REL_PATH}"
      APP_VOLUME_LABEL="${LIB_APP_SUPPORT_VOLUME_PREFIX} ${APP_NAME}"

      if ! diskutil info "${APP_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Creating APFS app-support subvolume '${APP_VOLUME_LABEL}' in ${LIB_APP_SUPPORT_CONTAINER_REF}"
        sudo diskutil apfs addVolume "${LIB_APP_SUPPORT_CONTAINER_REF}" APFS "${APP_VOLUME_LABEL}" || true
      fi

      if ! diskutil info "${APP_VOLUME_LABEL}" >/dev/null 2>&1; then
        echo "Warning: could not resolve app-support subvolume '${APP_VOLUME_LABEL}'; skipping ${APP_TARGET_PATH}."
        continue
      fi

      APP_VOLUME_UUID="$(diskutil info -plist "${APP_VOLUME_LABEL}" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
      if [[ -z "${APP_VOLUME_UUID:-}" ]]; then
        echo "Warning: could not get VolumeUUID for '${APP_VOLUME_LABEL}'; skipping ${APP_TARGET_PATH}."
        continue
      fi

      sudo mkdir -p "${APP_TARGET_PATH}"

      if [[ "${LIB_APP_SUPPORT_SUBVOLUME_FSTAB}" == "1" ]]; then
        APP_FSTAB_PREFIX="UUID=${APP_VOLUME_UUID} ${APP_TARGET_PATH} apfs"
        APP_FSTAB_LINE="${APP_FSTAB_PREFIX} ${LIB_APP_SUPPORT_SUBVOLUME_MOUNT_OPTS}"
        if ! grep -Fq "${APP_FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
          printf '%s\n' "${APP_FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
        fi
      fi

      if mount_volume_with_seed "${APP_VOLUME_LABEL}" "${APP_TARGET_PATH}"; then
        normalize_managed_path_permissions "${DATA_HOME_USER}" "${APP_TARGET_PATH}"
        echo "Mounted ${APP_VOLUME_LABEL} at ${APP_TARGET_PATH}"
        record_volume_status "app-support-${APP_NAME}" "${APP_VOLUME_LABEL}" "${APP_TARGET_PATH}" "success" "mounted"
      else
        echo "Warning: failed to mount ${APP_VOLUME_LABEL} at ${APP_TARGET_PATH}."
        record_volume_status "app-support-${APP_NAME}" "${APP_VOLUME_LABEL}" "${APP_TARGET_PATH}" "failed" "mount-failed"
      fi
    done
  fi
fi

: "Sanity checks"
if [[ "${USERS_RELOCATED}" -eq 1 ]]; then
  test -L /Users
else
  if [[ "${DATA_RELOCATE_USERS_ROOT}" == "1" ]]; then
    echo "Warning: /Users relocation was not applied on this run."
  else
    echo "Info: /Users relocation disabled (DATA_RELOCATE_USERS_ROOT=0)."
  fi
fi
test -d /private/var/lib
