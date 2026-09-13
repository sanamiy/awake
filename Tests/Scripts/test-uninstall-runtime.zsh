#!/bin/zsh -f
# Real removal script; every power, authorization and launchd boundary is mocked.
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
readonly task_root=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$task_root"' EXIT
export TEST_UNINSTALL_ROOT="$task_root"
export TEST_UNINSTALL_HOME="$task_root/user home"
/bin/mkdir -p "$task_root/runtime/bin" "$task_root/mock"
cat > "$task_root/runtime/bin/lid-awake" <<'RUNTIME'
PROGRAM_NAME=Fixture
DEFAULT_AUTHORIZER="$TEST_UNINSTALL_ROOT/mock/authorize"
LOG_FILE="$TEST_UNINSTALL_HOME/Library/Application Support/LidAwake/monitor.log"
acquire_lock() { print lock >> "$TEST_UNINSTALL_ROOT/trace"; }
release_lock() { print release >> "$TEST_UNINSTALL_ROOT/trace"; }
stop_session() { print stop >> "$TEST_UNINSTALL_ROOT/trace"; return "$TEST_STOP_EXIT"; }
clear_session_state() { print clear >> "$TEST_UNINSTALL_ROOT/trace"; }
fail() { print -u2 -- "$1"; exit "${2:-1}"; }
RUNTIME
cat > "$task_root/mock/authorize" <<'AUTHORIZE'
#!/bin/zsh -f
[[ "$1" == --authorize-remove ]] || exit 99
print authorize >> "$TEST_UNINSTALL_ROOT/trace"
(( TEST_AUTH_EXIT == 0 )) || exit "$TEST_AUTH_EXIT"
/bin/rm -f "$TEST_UNINSTALL_ROOT/rule"
AUTHORIZE
cat > "$task_root/mock/launchctl" <<'LAUNCHCTL'
#!/bin/zsh -f
[[ "$2" == "gui/${UID}/dev.lid-awake.recover" && $# == 2 ]] || exit 99
print -- "$1" >> "$TEST_UNINSTALL_ROOT/trace"
case "$1" in
  bootout) exit "$TEST_BOOTOUT_EXIT" ;;
  print) exit "$TEST_QUERY_EXIT" ;;
  *) exit 99 ;;
esac
LAUNCHCTL
/bin/chmod 755 "$task_root/mock/authorize" "$task_root/mock/launchctl"
python3 - "$PROJECT_DIR/runtime/uninstall.sh" "$task_root/runtime/uninstall.sh" "$task_root/mock/launchctl" <<'RENDER'
from pathlib import Path
import shlex, sys
body = Path(sys.argv[1]).read_text()
for old, new in [('${HOME}', '${TEST_UNINSTALL_HOME}'),
                 ('/etc/sudoers.d/lid-awake-${USER}', '${TEST_UNINSTALL_ROOT}/rule'),
                 ('/bin/launchctl ', shlex.quote(sys.argv[3]) + ' ')]:
    assert old in body, old
    body = body.replace(old, new)
Path(sys.argv[2]).write_text(body)
RENDER
readonly cli="$TEST_UNINSTALL_HOME/.local/bin/lid-awake"
readonly agent="$TEST_UNINSTALL_HOME/Library/LaunchAgents/dev.lid-awake.recover.plist"
readonly progress="$TEST_UNINSTALL_HOME/Library/Application Support/LidAwake/uninstall-state"
fail() {
  print -u2 -- "FAIL: $* (stop=$TEST_STOP_EXIT, auth=$TEST_AUTH_EXIT, bootout=$TEST_BOOTOUT_EXIT, query=$TEST_QUERY_EXIT)"
  /bin/cat "$task_root/output" >&2
  exit 1
}
reset_fixture() {
  /bin/mkdir -p "${cli:h}" "${agent:h}" "${progress:h}"
  touch "$cli" "$agent" "$task_root/rule"
  print cleaning > "$progress"
  : > "$task_root/trace"
  export TEST_STOP_EXIT=0 TEST_AUTH_EXIT=0 TEST_BOOTOUT_EXIT=0 TEST_QUERY_EXIT=113
}
run_uninstall() {
  local expected="$1" actual=0
  /bin/zsh -f "$task_root/runtime/uninstall.sh" > "$task_root/output" 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || fail "Expected exit $expected, got $actual"
  [[ "$(< "$progress")" == cleaning ]] || fail 'Removal must preserve UI progress'
}
reset_fixture
run_uninstall 0
[[ ! -e "$cli" && ! -e "$agent" && ! -e "$task_root/rule" ]] || fail 'Cleanup left runtime files'
[[ "$(/usr/bin/tr '\n' ',' < "$task_root/trace")" == 'lock,stop,authorize,bootout,print,clear,release,' ]] || fail 'Wrong cleanup ordering'
export TEST_BOOTOUT_EXIT=113
run_uninstall 0 # Retry after files and registration are already absent.
for code in 80 81 85; do
  reset_fixture
  export TEST_STOP_EXIT="$code"
  run_uninstall "$code"
  [[ -e "$cli" && -e "$agent" && -e "$task_root/rule" ]] || fail 'Power failure removed recovery resources'
  [[ "$(/usr/bin/tr '\n' ',' < "$task_root/trace")" == 'lock,stop,release,' ]] || fail 'Cleanup ran after failed restoration'
done
reset_fixture
export TEST_AUTH_EXIT=82
run_uninstall 82
[[ -e "$cli" && -e "$agent" && -e "$task_root/rule" ]] || fail 'Cancelled authorization removed files'
for query_code in 0 5 112; do
  for bootout_code in 0 5; do
    reset_fixture
    export TEST_BOOTOUT_EXIT="$bootout_code" TEST_QUERY_EXIT="$query_code"
    run_uninstall 83
    [[ -e "$cli" && -e "$agent" ]] || fail 'Unconfirmed removal deleted runtime files'
  done
done
reset_fixture
export TEST_BOOTOUT_EXIT=5 TEST_QUERY_EXIT=113
run_uninstall 0 # Failed bootout is harmless only when absence is confirmed.
print 'PASS: uninstall ordering, verified service absence, query failures, retry, cancellation and retained progress'
