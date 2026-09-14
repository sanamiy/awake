#!/bin/zsh -f

set -eu

readonly RUNTIME_DIR="${0:A:h}"
source "${RUNTIME_DIR}/bin/lid-awake"

readonly INSTALL_BIN="${HOME}/.local/bin/lid-awake"
readonly INSTALL_RECOVERY="${HOME}/.local/bin/AwakeRecovery"
readonly LAUNCH_AGENT="${HOME}/Library/LaunchAgents/dev.lid-awake.recover.plist"
readonly SUDOERS_FILE="/etc/sudoers.d/lid-awake-${USER}"
readonly AUTHORIZER="${LID_AWAKE_AUTHORIZER:-${DEFAULT_AUTHORIZER}}"

acquire_lock || fail "別の操作が実行中です。後でもう一度実行してください。" 73
trap release_lock EXIT
if stop_session 1; then
  :
else
  task_stop_code=$?
  fail "解除に失敗したため、アンインストールを中断しました。ファイルと復旧設定は保持しています。" "$task_stop_code"
fi

if [[ -e "$SUDOERS_FILE" ]]; then
  [[ -x "$AUTHORIZER" ]] || fail "セットアップの削除には${PROGRAM_NAME}アプリが必要です。" 83
  "$AUTHORIZER" --authorize-remove
fi

readonly RECOVERY_SERVICE="gui/${UID}/dev.lid-awake.recover"
# Target the service, not its plist: retry must work even if the plist is missing.
task_bootout_code=0
/bin/launchctl bootout "$RECOVERY_SERVICE" || task_bootout_code=$?
task_query_code=0
/bin/launchctl print "$RECOVERY_SERVICE" >/dev/null 2>&1 || task_query_code=$?
# macOS launchctl error 113 = service not found; 112 = domain not found.
# Only positive absence is success, never an arbitrary query/bootout failure.
[[ "$task_query_code" == 113 ]] ||
  fail "復旧サービスの解除を確認できません（解除: ${task_bootout_code}、確認: ${task_query_code}）。残りのファイルは保持しています。" 83
/bin/rm -f "$LAUNCH_AGENT"
/bin/rm -f "$INSTALL_BIN"
/bin/rm -f "$INSTALL_RECOVERY"
/bin/rmdir "${HOME}/.local/bin" >/dev/null 2>&1 || true
clear_session_state
/bin/rm -f "$LOG_FILE"
# Keep the lock inode: an already waiting process must not lock a different file.

print -- "${PROGRAM_NAME}の電源制御のセットアップを削除しました。アプリ本体と保存設定は保持しています。"
