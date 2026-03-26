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
: "${DATA_DISK_NAME:=User Data}"
: "${DATA_DISK_USER_DATA_NAME:=${DATA_DISK_NAME}}"
: "${DATA_DISK_USER_LIBRARY_NAME:=User Library}"
: "${DATA_DISK_GIT_STORE_NAME:=Git Store}"
: "${DATA_DISK_NIX_STORE_NAME:=Nix Store}"
: "${DATA_DISK_BUILD_CHAINS_NAME:=Build Chains}"
: "${DATA_RELOCATE_LIBRARY:=0}"
: "${DATA_HOME_PARENT_DIR:=user-home}"
: "${DATA_COPY_USER_LIBRARY:=1}"
: "${DATA_COPY_GIT_STORE:=1}"
: "${DATA_COPY_NIX_STORE:=0}"
: "${DATA_COPY_BUILD_CHAINS:=1}"
: "${GIT_STORE_CONFIGURE_SYSTEM_MOUNT:=1}"
: "${GIT_STORE_SYSTEM_MOUNT_POINT:=/private/var/lib/git}"
: "${NIX_STORE_CONFIGURE_SYSTEM_MOUNT:=1}"
: "${NIX_STORE_SYSTEM_MOUNT_POINT:=/nix}"
: "${NIX_STORE_CONFIGURE_SYNTHETIC:=1}"

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
GIT_STORE_VOL_REF=""
NIX_STORE_VOL_REF=""

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
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_USER_LIBRARY_NAME}" ]]; then
    USER_LIBRARY_MOUNT_POINT="${DATA_MOUNT_POINT}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_GIT_STORE_NAME}" ]]; then
    GIT_STORE_MOUNT_POINT="${DATA_MOUNT_POINT}"
    GIT_STORE_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_NIX_STORE_NAME}" ]]; then
    NIX_STORE_MOUNT_POINT="${DATA_MOUNT_POINT}"
    NIX_STORE_VOL_REF="${DATA_VOL_REF}"
  elif [[ "${DATA_DISK_LABEL}" == "${DATA_DISK_BUILD_CHAINS_NAME}" ]]; then
    BUILD_CHAINS_MOUNT_POINT="${DATA_MOUNT_POINT}"
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

      sudo mkdir -p "${NIX_STORE_SYSTEM_MOUNT_POINT}"

      FSTAB_PREFIX="UUID=${NIX_VOLUME_UUID} ${NIX_STORE_SYSTEM_MOUNT_POINT} apfs"
      FSTAB_LINE="${FSTAB_PREFIX} rw,nobrowse"
      if ! grep -Fq "${FSTAB_PREFIX}" /etc/fstab 2>/dev/null; then
        printf '%s\n' "${FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
      fi

      if ! volume_mounted_at_target "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}"; then
        sudo diskutil unmount "${NIX_STORE_VOL_REF}" >/dev/null 2>&1 || true
        sudo diskutil mount -mountPoint "${NIX_STORE_SYSTEM_MOUNT_POINT}" "${NIX_STORE_VOL_REF}" || true
      fi

      if volume_mounted_at_target "${NIX_STORE_VOL_REF}" "${NIX_STORE_SYSTEM_MOUNT_POINT}"; then
        echo "Nix Store mounted at ${NIX_STORE_SYSTEM_MOUNT_POINT} using volume ${NIX_STORE_VOL_REF} (${NIX_VOLUME_UUID})."
      else
        echo "Warning: could not mount ${NIX_STORE_VOL_REF} at ${NIX_STORE_SYSTEM_MOUNT_POINT}; verify /etc/fstab and retry after reboot."
      fi
    fi
  else
    echo "Warning: Nix Store volume ref not detected; skipping ${NIX_STORE_SYSTEM_MOUNT_POINT} mount setup."
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
      else
        echo "Warning: could not mount ${GIT_STORE_VOL_REF} at ${GIT_STORE_SYSTEM_MOUNT_POINT}; verify /etc/fstab and retry after reboot."
      fi
    fi
  else
    echo "Warning: Git Store volume ref not detected; skipping ${GIT_STORE_SYSTEM_MOUNT_POINT} mount setup."
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
DATA_HOME_USER="$(resolve_data_home_user)"
ACTUAL_HOME_DIR="$(resolve_home_dir_for_user "${DATA_HOME_USER}")"
if [[ ! -L /Users ]]; then
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
if [[ "${USERS_RELOCATED}" -eq 0 ]]; then
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
fi

: "Relocate /private/var/lib to data volume"
if [[ -d /private/var/lib && ! -L /private/var/lib ]]; then
  sudo mkdir -p "${DATA_MOUNT_POINT}/var-lib"
  sudo ditto /private/var/lib "${DATA_MOUNT_POINT}/var-lib"
  sudo mv /private/var/lib /private/var/lib.local
  sudo ln -s "${DATA_MOUNT_POINT}/var-lib" /private/var/lib
fi

: "Ensure /private/var/lib link exists"
if [[ ! -e /private/var/lib ]]; then
  sudo mkdir -p "${DATA_MOUNT_POINT}/var-lib"
  sudo ln -s "${DATA_MOUNT_POINT}/var-lib" /private/var/lib
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

: "Sanity checks"
if [[ "${USERS_RELOCATED}" -eq 1 ]]; then
  test -L /Users
else
  echo "Warning: /Users relocation was not applied on this run."
fi
test -L /private/var/lib
