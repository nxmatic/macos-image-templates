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

: "${ENABLE_SAFARI_REMOTE_AUTOMATION:=1}"
: "${PRIMARY_ACCOUNT_NAME:=admin}"
: "${PRIMARY_ACCOUNT_FULL_NAME:=Stephane Lacoin (aka nxmatic)}"
: "${PRIMARY_ACCOUNT_ALIAS:=nxmatic}"

PRIMARY_ACCOUNT_HOME="$(dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${PRIMARY_ACCOUNT_HOME}" ]]; then
	PRIMARY_ACCOUNT_HOME="/Users/${PRIMARY_ACCOUNT_NAME}"
fi

: "Enable passwordless sudo"
echo admin | sudo -S sh -c "mkdir -p /etc/sudoers.d/; echo '${PRIMARY_ACCOUNT_NAME} ALL=(ALL) NOPASSWD: ALL' | EDITOR=tee visudo /etc/sudoers.d/${PRIMARY_ACCOUNT_NAME}-nopasswd"

: "Set preferred full account name"
if dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" >/dev/null 2>&1; then
	sudo dscl . -create "/Users/${PRIMARY_ACCOUNT_NAME}" RealName "${PRIMARY_ACCOUNT_FULL_NAME}" || true
fi

: "Add optional short-name alias for convenience"
if [[ -n "${PRIMARY_ACCOUNT_ALIAS}" && "${PRIMARY_ACCOUNT_ALIAS}" != "${PRIMARY_ACCOUNT_NAME}" ]]; then
	EXISTING_RECORD_NAMES="$(dscl . -read "/Users/${PRIMARY_ACCOUNT_NAME}" RecordName 2>/dev/null || true)"
	if ! grep -Eq "(^|[[:space:]])${PRIMARY_ACCOUNT_ALIAS}([[:space:]]|$)" <<<"${EXISTING_RECORD_NAMES}"; then
		sudo dscl . -append "/Users/${PRIMARY_ACCOUNT_NAME}" RecordName "${PRIMARY_ACCOUNT_ALIAS}" || true
	fi
fi

: "Enable auto-login"
: "See https://github.com/xfreebird/kcpassword for details."
echo '00000000: 1ced 3f4a bcbc ba2c caca 4e82' | sudo xxd -r - /etc/kcpassword
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${PRIMARY_ACCOUNT_NAME}"

: "Disable screensaver at login screen"
sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0

: "Disable screensaver for admin user"
defaults -currentHost write com.apple.screensaver idleTime 0

: "Prevent the VM from sleeping"
sudo systemsetup -setsleep Off 2>/dev/null

if [[ "${ENABLE_SAFARI_REMOTE_AUTOMATION}" == "1" ]]; then
	: "Launch Safari to populate defaults"
	/Applications/Safari.app/Contents/MacOS/Safari &
	SAFARI_PID=$!
	disown
	sleep 30
	kill -9 "$SAFARI_PID"

	: "Enable Safari remote automation"
	sudo safaridriver --enable
else
	: "Skip Safari bootstrap and remote automation setup"
fi

: "Disable screen lock (works for logged-in user session)"
sysadminctl -screenLock off -password admin

: "Disable Siri for the user session"
defaults write com.apple.assistant.support "Assistant Enabled" -bool false
defaults write com.apple.Siri StatusMenuVisible -bool false

: "Ensure expected home path exists for primary account"
if [[ ! -d "${PRIMARY_ACCOUNT_HOME}" ]]; then
	echo "Warning: expected home directory does not exist for ${PRIMARY_ACCOUNT_NAME}: ${PRIMARY_ACCOUNT_HOME}" >&2
fi

: "Ensure FileVault is not enabled by automation"
# OOBE already selects 'Not Now'; this is a safety check/log point.
fdesetup status || true

: "Configure Software Update: check + download only, no auto-install"
sudo softwareupdate --schedule on
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool false
