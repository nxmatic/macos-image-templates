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

: "${NIX_INSTALLER_URL:=https://artifacts.nixos.org/nix-installer}"
: "${NIX_INSTALLER_PATH:=/private/tmp/nix-installer}"
: "${NIX_INSTALL_AT_BUILD:=1}"
: "${NIX_INSTALL_ALLOW_UNMOUNTED_NIX:=1}"
: "${NIX_EXPECTED_VOLUME_LABEL:=Nix Store}"
: "${NIX_REQUIRE_EXISTING_STORE_VOLUME:=1}"
: "${FLOX_INSTALL_WITH_NIX:=1}"
: "${FLOX_INSTALL_REF:=github:flox/flox}"
: "${NIX_DARWIN_INSTALL_WITH_NIX:=1}"
: "${NIX_DARWIN_INSTALL_REF:=nix-darwin/nix-darwin}"
: "${NIX_BOOTSTRAP_USER:=${DATA_HOME_USER:-${PRIMARY_ACCOUNT_NAME:-}}}"

: "Fetch modern Nix installer"
sudo mkdir -p "$(dirname "${NIX_INSTALLER_PATH}")"
curl -fsSL "${NIX_INSTALLER_URL}" -o "${NIX_INSTALLER_PATH}"
sudo chmod 0755 "${NIX_INSTALLER_PATH}"

if [[ "${NIX_INSTALL_AT_BUILD}" != "1" ]]; then
  echo "Nix installer staged at ${NIX_INSTALLER_PATH}."
  echo "Deferred install mode (NIX_INSTALL_AT_BUILD=${NIX_INSTALL_AT_BUILD})."
  echo "Run after first reboot: sudo bash -x '${NIX_INSTALLER_PATH}' install"
  if [[ "${FLOX_INSTALL_WITH_NIX}" == "1" ]]; then
    echo "Flox install deferred as well (requires Nix to be installed first)."
  fi
  if [[ "${NIX_DARWIN_INSTALL_WITH_NIX}" == "1" ]]; then
    echo "nix-darwin install deferred as well (requires Nix to be installed first)."
  fi
  exit 0
fi

if ! mount | grep -Eq ' on /nix '; then
  echo "Info: /nix is not currently mounted; delegating mount/bootstrap handling to the Nix installer."
fi

device_identifier_for_ref() {
  local ref="$1"
  diskutil info -plist "${ref}" | plutil -extract DeviceIdentifier raw -o - - 2>/dev/null || true
}

verify_nix_mount_matches_expected() {
  local vol_label="$1"
  local require_existing="$2"
  local expected_dev=""
  local mounted_dev=""

  if ! mount | grep -Eq ' on /nix '; then
    return 1
  fi

  mounted_dev="$(device_identifier_for_ref /nix)"
  expected_dev="$(device_identifier_for_ref "${vol_label}")"

  if [[ "${require_existing}" == "1" && -n "${expected_dev}" && "${mounted_dev}" != "${expected_dev}" ]]; then
    echo "Error: /nix is mounted from '${mounted_dev:-unknown}', expected '${expected_dev}' (${vol_label})." >&2
    return 2
  fi

  echo "Confirmed /nix is mounted from expected volume (${vol_label}, ${mounted_dev:-unknown})."
  return 0
}

ensure_nix_mountpoint_uses_expected_volume() {
  local vol_label="$1"
  local require_existing="$2"
  local apfs_boot_util_bin="/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_boot_util"

  if verify_nix_mount_matches_expected "${vol_label}" "${require_existing}"; then
    return 0
  fi

  if [[ $? -eq 2 ]]; then
    exit 1
  fi

  if ! diskutil info "${vol_label}" >/dev/null 2>&1; then
    if [[ "${require_existing}" == "1" ]]; then
      echo "Error: expected APFS volume '${vol_label}' not found; refusing to let installer create a duplicate store volume." >&2
      echo "       Set NIX_REQUIRE_EXISTING_STORE_VOLUME=0 to allow installer-managed volume creation." >&2
      exit 1
    fi
    return 0
  fi

  if [[ -e /nix ]]; then
    echo "Info: /nix path already exists; checking mount state before APFS boot phases."
  else
    echo "Info: /nix path does not exist yet; applying APFS boot phases to realize synthetic mountpoint."
  fi

  if [[ -x "${apfs_boot_util_bin}" ]]; then
    echo "Applying APFS boot mount phases to activate synthetic/fstab mounts for /nix."
    sudo "${apfs_boot_util_bin}" 1 || true
    sudo "${apfs_boot_util_bin}" 2 || true
  else
    echo "Warning: apfs_boot_util not found at ${apfs_boot_util_bin}."
  fi

  if ! verify_nix_mount_matches_expected "${vol_label}" "${require_existing}"; then
    if [[ "${require_existing}" == "1" ]]; then
      echo "Error: expected volume '${vol_label}' exists but /nix is not correctly mounted after apfs_boot_util phases; refusing installer run to avoid duplicate volume creation." >&2
    fi
    exit 1
  fi
}

ensure_nix_mountpoint_uses_expected_volume "${NIX_EXPECTED_VOLUME_LABEL}" "${NIX_REQUIRE_EXISTING_STORE_VOLUME}"

: "Run modern Nix installer"
sudo bash -x "${NIX_INSTALLER_PATH}" install macos --no-confirm --volume-label "${NIX_EXPECTED_VOLUME_LABEL}"

if ! verify_nix_mount_matches_expected "${NIX_EXPECTED_VOLUME_LABEL}" "${NIX_REQUIRE_EXISTING_STORE_VOLUME}"; then
  echo "Error: after installer run, /nix is not mounted from expected Nix store volume." >&2
  exit 1
fi

if [[ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

ensure_nix_custom_conf_block() {
  local conf_file="/etc/nix/nix.custom.conf"
  local block_begin="# BEGIN macos-image-template nix custom"
  local block_end="# END macos-image-template nix custom"
  local tmp_file

  sudo install -d -m 0755 /etc/nix
  sudo touch "${conf_file}"

  if sudo grep -Fq "${block_begin}" "${conf_file}"; then
    tmp_file="$(mktemp)"
    sudo awk -v begin="${block_begin}" -v end="${block_end}" '
      $0 == begin { skip = 1; next }
      $0 == end   { skip = 0; next }
      skip != 1   { print }
    ' "${conf_file}" | cat > "${tmp_file}"
    sudo mv "${tmp_file}" "${conf_file}"
  fi

  {
    printf '%s\n' "${block_begin}"
    printf '%s\n' 'accept-flake-config = true'
    printf '%s\n' 'extra-trusted-substituters = https://cache.flox.dev'
    printf '%s\n' 'extra-trusted-public-keys = flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs='
    printf '%s\n' "${block_end}"
  } | sudo tee -a "${conf_file}" >/dev/null
}

ensure_nix_custom_conf_block

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

NIX_PROFILE_USER="${NIX_BOOTSTRAP_USER}"
if [[ -z "${NIX_PROFILE_USER}" ]]; then
  NIX_PROFILE_USER="$(id -un)"
fi
NIX_PROFILE_HOME="$(resolve_home_dir_for_user "${NIX_PROFILE_USER}")"

NIX_BIN=""
for candidate in \
  "/nix/var/nix/profiles/default/bin/nix" \
  "${NIX_PROFILE_HOME}/.nix-profile/bin/nix" \
  "${HOME}/.nix-profile/bin/nix" \
  "$(command -v nix 2>/dev/null || true)"; do
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    NIX_BIN="${candidate}"
    break
  fi
done

if [[ -z "${NIX_BIN}" ]]; then
  echo "Warning: Nix binary not found after install; skipping package bootstrap (git/flox/nix-darwin)."
  exit 0
fi

ensure_profile_user_writable_state() {
  local user="$1"
  local home="$2"
  local path

  for path in "${home}/.cache" "${home}/.cache/nix" "${home}/.local/state/nix"; do
    sudo mkdir -p "${path}"
    sudo chown -R "${user}:staff" "${path}" >/dev/null 2>&1 || true
    sudo chmod -R u+rwX "${path}" >/dev/null 2>&1 || true
  done
}

ensure_profile_user_writable_state "${NIX_PROFILE_USER}" "${NIX_PROFILE_HOME}"

run_nix_profile_add() {
  local pkg_ref="$1"

  if [[ "$(id -u)" -eq 0 && "${NIX_PROFILE_USER}" != "root" ]]; then
    sudo -u "${NIX_PROFILE_USER}" -H env HOME="${NIX_PROFILE_HOME}" "${NIX_BIN}" profile add --accept-flake-config "${pkg_ref}"
  else
    "${NIX_BIN}" profile add --accept-flake-config "${pkg_ref}"
  fi
}

target_command_exists() {
  local cmd="$1"

  if [[ "$(id -u)" -eq 0 && "${NIX_PROFILE_USER}" != "root" ]]; then
    sudo -u "${NIX_PROFILE_USER}" -H env HOME="${NIX_PROFILE_HOME}" bash -lc "command -v ${cmd} >/dev/null 2>&1"
  else
    command -v "${cmd}" >/dev/null 2>&1
  fi
}

: "Install git via Nix profile first (required for git-based flakes/inputs)"
if target_command_exists git || [[ -x "/nix/var/nix/profiles/default/bin/git" ]] || [[ -x "${NIX_PROFILE_HOME}/.nix-profile/bin/git" ]]; then
  echo "Git already available; skipping install."
else
  run_nix_profile_add "nixpkgs#git"
fi

if [[ "${FLOX_INSTALL_WITH_NIX}" == "1" ]]; then
  : "Install Flox via Nix profile (idempotent)"
  if target_command_exists flox || [[ -x "/nix/var/nix/profiles/default/bin/flox" ]] || [[ -x "${NIX_PROFILE_HOME}/.nix-profile/bin/flox" ]]; then
    echo "Flox already available; skipping install."
  else
    run_nix_profile_add "${FLOX_INSTALL_REF}"
  fi
fi

if [[ "${NIX_DARWIN_INSTALL_WITH_NIX}" == "1" ]]; then
  : "Install nix-darwin via Nix profile (idempotent)"
  if target_command_exists darwin-rebuild || [[ -x "/nix/var/nix/profiles/default/bin/darwin-rebuild" ]] || [[ -x "${NIX_PROFILE_HOME}/.nix-profile/bin/darwin-rebuild" ]]; then
    echo "nix-darwin already available (darwin-rebuild found); skipping install."
  else
    run_nix_profile_add "${NIX_DARWIN_INSTALL_REF}"
  fi
fi
