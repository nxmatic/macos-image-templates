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
: "${NIX_INSTALL_AT_BUILD:=0}"
: "${NIX_INSTALL_ALLOW_UNMOUNTED_NIX:=0}"

: "Fetch modern Nix installer"
sudo mkdir -p "$(dirname "${NIX_INSTALLER_PATH}")"
curl -fsSL "${NIX_INSTALLER_URL}" -o "${NIX_INSTALLER_PATH}"
sudo chmod 0755 "${NIX_INSTALLER_PATH}"

if [[ "${NIX_INSTALL_AT_BUILD}" != "1" ]]; then
  echo "Nix installer staged at ${NIX_INSTALLER_PATH}."
  echo "Deferred install mode (NIX_INSTALL_AT_BUILD=${NIX_INSTALL_AT_BUILD})."
  echo "Run after first reboot: sudo bash -x '${NIX_INSTALLER_PATH}' install"
  exit 0
fi

if [[ "${NIX_INSTALL_ALLOW_UNMOUNTED_NIX}" != "1" ]] && ! mount | grep -Eq ' on /nix '; then
  echo "Warning: /nix is not mounted yet; skipping in-build Nix install."
  echo "Run after reboot when /nix is mounted: sudo bash -x '${NIX_INSTALLER_PATH}' install"
  exit 0
fi

: "Run modern Nix installer"
sudo bash -x "${NIX_INSTALLER_PATH}" install
