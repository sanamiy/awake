#!/bin/zsh -f

set -eu

readonly RUNTIME_DIR="${0:A:h}"
readonly SOURCE_BIN="${RUNTIME_DIR}/bin/lid-awake"
source "$SOURCE_BIN"
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly INSTALL_BIN="${INSTALL_DIR}/lid-awake"
readonly SOURCE_RECOVERY="${RUNTIME_DIR}/../../Helpers/AwakeRecovery"
readonly INSTALL_RECOVERY="${INSTALL_DIR}/AwakeRecovery"
readonly LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
readonly LAUNCH_AGENT="${LAUNCH_AGENTS_DIR}/dev.lid-awake.recover.plist"
readonly SUDOERS_FILE="/etc/sudoers.d/lid-awake-${USER}"

[[ "$USER" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 -- "安全に扱えないユーザー名です: $USER"
  exit 64
}

print -- "${PROGRAM_NAME}のランタイムと復旧機能を配置します。"
print -- "管理者権限は、pmsetのdisablesleepをON/OFFする2コマンドだけに許可します。"
# Installer owns privileged setup. This user-scoped stage never requests authorization.
if [[ ! -e "$SUDOERS_FILE" ]] || ! sudo_rule_available; then
  print -u2 "権限設定がありません。${PROGRAM_NAME}のPKGインストーラーを再実行してください。"
  exit 78
fi

acquire_lock || fail "別の操作が実行中です。後でもう一度インストーラーを実行してください。" 73
trap release_lock EXIT
stop_session 1 || fail "電源設定を復旧してからインストーラーを再実行してください。" $?
/bin/mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR"
/usr/bin/install -m 755 "$SOURCE_BIN" "$INSTALL_BIN"
/usr/bin/install -m 755 "$SOURCE_RECOVERY" "$INSTALL_RECOVERY"
/usr/bin/plutil -create xml1 "$LAUNCH_AGENT"
/usr/bin/plutil -insert Label -string dev.lid-awake.recover "$LAUNCH_AGENT"
# Attribution also requires the executable to have the app's signing Team ID.
/usr/bin/plutil -insert AssociatedBundleIdentifiers -array "$LAUNCH_AGENT"
/usr/bin/plutil -insert AssociatedBundleIdentifiers.0 -string "$PROGRAM_BUNDLE_ID" "$LAUNCH_AGENT"
/usr/bin/plutil -insert ProgramArguments -array "$LAUNCH_AGENT"
/usr/bin/plutil -insert ProgramArguments.0 -string "$INSTALL_RECOVERY" "$LAUNCH_AGENT"
/usr/bin/plutil -insert RunAtLoad -bool YES "$LAUNCH_AGENT"
/usr/bin/plutil -lint "$LAUNCH_AGENT"
/bin/launchctl bootout "gui/${UID}" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
/bin/launchctl enable "gui/${UID}/dev.lid-awake.recover"
/bin/launchctl bootstrap "gui/${UID}" "$LAUNCH_AGENT"
/bin/launchctl print "gui/${UID}/dev.lid-awake.recover" >/dev/null

print -- ""
print -- "インストール完了: ${INSTALL_BIN}"
print -- "開始ショートカットとスリープ防止の時間は${PROGRAM_NAME}アプリで設定できます。"
print -- ""
show_status
# A successful PKG setup starts a fresh installation, including same-version reinstalls.
/bin/rm -f "${HOME}/Library/Application Support/LidAwake/uninstall-state"
