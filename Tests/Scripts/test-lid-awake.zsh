#!/bin/zsh -f

set -eu

readonly PROJECT_DIR="${0:A:h:h:h}"
readonly TEMP_DIR="$(/usr/bin/mktemp -d)"
export TEST_HOME="${TEMP_DIR}/home"
readonly MOCK_DIR="${TEMP_DIR}/mock"
readonly TEST_BIN="${TEMP_DIR}/lid-awake"

cleanup() {
  /bin/rm -f "${TEMP_DIR}/fail-restore" "${TEMP_DIR}/unknown-state" "${TEMP_DIR}/slow-restore"
  "$TEST_BIN" stop >/dev/null 2>&1 || true
  if [[ "${LID_AWAKE_TEST_KEEP:-0}" == 1 ]]; then
    print -u2 -- "Test artifacts: $TEMP_DIR"
    return
  fi
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

/bin/mkdir -p "$TEST_HOME" "$MOCK_DIR"
print -r -- "0" > "${TEMP_DIR}/sleep-disabled"
print -r -- "Battery Power" > "${TEMP_DIR}/power-source"
print -r -- "80" > "${TEMP_DIR}/battery-percent"

cat > "${MOCK_DIR}/pmset" <<'MOCK_PMSET'
#!/bin/zsh -f
set -eu
case "$1 $2" in
  "-g batt")
    source=$(/bin/cat "${LID_AWAKE_TEST_ROOT}/power-source")
    percent=$(/bin/cat "${LID_AWAKE_TEST_ROOT}/battery-percent")
    print -r -- "$source:$percent" >> "${LID_AWAKE_TEST_ROOT}/power-checks"
    print -- "Now drawing from '${source}'"
    print -- " -InternalBattery-0\t${percent}%; discharging; present: true"
    ;;
  "-a disablesleep")
    print -r -- "$3" >> "${LID_AWAKE_TEST_ROOT}/pmset-calls"
    if [[ "$3" == 0 && -e "${LID_AWAKE_TEST_ROOT}/fail-restore" ]]; then
      exit 1
    fi
    if [[ "$3" == 0 && -e "${LID_AWAKE_TEST_ROOT}/slow-restore" ]]; then
      /bin/sleep 3
    fi
    print -r -- "$3" > "${LID_AWAKE_TEST_ROOT}/sleep-disabled"
    if [[ "$3" == 0 && -e "${LID_AWAKE_TEST_ROOT}/unknown-after-restore" ]]; then
      touch "${LID_AWAKE_TEST_ROOT}/unknown-state"
    fi
    ;;
  *)
    print -u2 -- "unexpected pmset arguments: $*"
    exit 64
    ;;
esac
MOCK_PMSET

cat > "${MOCK_DIR}/sudo" <<'MOCK_SUDO'
#!/bin/zsh -f
set -eu
[[ "$1" == "-n" ]] || exit 64
shift
if [[ "$1" == "-l" ]]; then
  [[ ! -e "${LID_AWAKE_TEST_ROOT}/fail-permission" ]] || exit 1
  exit 0
fi
exec "$@"
MOCK_SUDO

cat > "${MOCK_DIR}/ioreg" <<'MOCK_IOREG'
#!/bin/zsh -f
set -eu
print read >> "${LID_AWAKE_TEST_ROOT}/ioreg-reads"
if [[ -e "${LID_AWAKE_TEST_ROOT}/fail-repeated-read" ]] && (( $(/usr/bin/wc -l < "${LID_AWAKE_TEST_ROOT}/ioreg-reads") > 1 )); then
  exit 1
fi
[[ ! -e "${LID_AWAKE_TEST_ROOT}/unknown-state" ]] || exit 1
value=$(/bin/cat "${LID_AWAKE_TEST_ROOT}/sleep-disabled")
if [[ "$value" == "1" ]]; then
  print -- '    "SleepDisabled" = Yes'
else
  print -- '    "SleepDisabled" = No'
fi
MOCK_IOREG

cat > "${MOCK_DIR}/osascript" <<'MOCK_OSASCRIPT'
#!/bin/zsh -f
print -r -- "$*" >> "${LID_AWAKE_TEST_ROOT}/notifications"
/bin/cat >/dev/null
exit 0
MOCK_OSASCRIPT

/bin/chmod 755 "${MOCK_DIR}/pmset" "${MOCK_DIR}/ioreg" "${MOCK_DIR}/sudo" "${MOCK_DIR}/osascript"

python3 "$PROJECT_DIR/scripts/configure.py" --runtime-dir "$TEMP_DIR/rendered-runtime"
python3 - "$TEMP_DIR/rendered-runtime/bin/lid-awake" "$TEST_BIN" "$MOCK_DIR" <<'PY_FIXTURE'
from pathlib import Path
import shlex, sys
source, output, mocks = map(Path, sys.argv[1:])
body = source.read_text().replace('${HOME}', '${TEST_HOME}')
for name, system, mock in [('PMSET', '/usr/bin/pmset', 'pmset'),
                           ('IOREG', '/usr/sbin/ioreg', 'ioreg'),
                           ('SUDO', '/usr/bin/sudo', 'sudo'),
                           ('OSASCRIPT', '/usr/bin/osascript', 'osascript')]:
    old = f'readonly {name}="{system}"'
    if body.count(old) != 1:
        raise SystemExit(f'Cannot isolate {name}')
    body = body.replace(old, f'readonly {name}={shlex.quote(str(mocks / mock))}')
output.write_text(body.replace('/bin/sleep 15', '/bin/sleep 0.1'))
PY_FIXTURE
/bin/chmod 755 "$TEST_BIN"
if [[ "${LID_AWAKE_TEST_TRACE:-0}" == 1 ]]; then
  /usr/bin/sed -i '' 's/^set -u$/set -ux/' "$TEST_BIN"
fi

export LID_AWAKE_TEST_ROOT="$TEMP_DIR"

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

# Exit codes, not localized text, are the command contract.
assert_exit() {
  local expected="$1" actual=0
  shift
  "$@" > "$TEMP_DIR/code-output" 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || fail "Expected exit $expected, got $actual: $*"
}

assert_sleep_disabled() {
  local expected="$1"
  local actual=$(/bin/cat "${TEMP_DIR}/sleep-disabled")
  if [[ "$actual" != "$expected" ]]; then
    [[ -r "${TEST_HOME}/Library/Application Support/LidAwake/monitor.log" ]] &&
      /bin/cat "${TEST_HOME}/Library/Application Support/LidAwake/monitor.log" >&2
    fail "disablesleep: expected ${expected}, got ${actual}"
  fi
}

# Removed public start aliases must not enable sleep prevention.
for action in start arm toggle; do
  if "$TEST_BIN" "$action" >/dev/null 2>&1; then fail "Removed command accepted: $action"; fi
  assert_sleep_disabled 0
done
# Unknown options must fail before any power change.
for action in _start stop recover status _recover; do
  assert_exit 64 "$TEST_BIN" "$action" --lock
  assert_sleep_disabled 0
done
[[ ! -e "${TEMP_DIR}/pmset-calls" ]] || fail "Removed --lock changed power settings"

# No defaults or ignored start options on diagnostic/stop commands.
for action in stop recover status _recover; do
  assert_exit 64 "$TEST_BIN" "$action" --minutes 1
  assert_exit 64 "$TEST_BIN" "$action" --min-battery 30
done
assert_exit 64 "$TEST_BIN" _start
assert_exit 64 "$TEST_BIN" _start --minutes 1
assert_exit 64 "$TEST_BIN" _start --min-battery 30
assert_exit 64 "$TEST_BIN" _start --minutes 1 --minutes 2
[[ ! -e "${TEMP_DIR}/pmset-calls" ]] || fail "Invalid arguments changed power settings"

# Input bounds: exercise behavior, not the spelling of shell comparisons.
# AC power prevents the runtime's battery cutoff from masking validation results.
print 'AC Power' > "$TEMP_DIR/power-source"
while read -r minutes battery expected; do
  : > "$TEMP_DIR/pmset-calls"
  assert_exit "$expected" "$TEST_BIN" _start --minutes "$minutes" --min-battery "$battery"
  if (( expected == 0 )); then
    assert_exit 0 "$TEST_BIN" stop
  else
    [[ ! -s "$TEMP_DIR/pmset-calls" ]] || fail "Invalid bounds changed power: $minutes/$battery"
  fi
  assert_sleep_disabled 0
done <<'BOUNDARIES'
1 5 0
1 95 0
1440 5 0
1440 95 0
0 30 0
-1 30 64
1441 30 64
120 4 64
120 96 64
BOUNDARIES
print 'Battery Power' > "$TEMP_DIR/power-source"

# Shared stop/recovery decision table, without a background monitor.
touch "$TEMP_DIR/fail-repeated-read"
: > "$TEMP_DIR/ioreg-reads"
assert_exit 0 "$TEST_BIN" status
[[ "$(/usr/bin/wc -l < "$TEMP_DIR/ioreg-reads" | /usr/bin/tr -d ' ')" == 1 ]] || fail 'Status must use one power snapshot'
/bin/rm "$TEMP_DIR/fail-repeated-read"
touch "$TEMP_DIR/unknown-state"
assert_exit 2 "$TEST_BIN" status
/bin/rm "$TEMP_DIR/unknown-state"
state_dir="${TEST_HOME}/Library/Application Support/LidAwake"
for action in stop recover _recover; do
  for owned in 0 1; do
    for live_state in allowed prevented unknown; do
      /bin/mkdir -p "$state_dir"
      /bin/rm -f "$state_dir/session-token" "$TEMP_DIR/unknown-state"
      (( owned )) && print -r -- fixture > "$state_dir/session-token"
      print -r -- 1 > "$TEMP_DIR/sleep-disabled"
      expected=0
      case "$live_state" in
        allowed) print -r -- 0 > "$TEMP_DIR/sleep-disabled" ;;
        prevented) (( owned )) || expected=85 ;;
        unknown) touch "$TEMP_DIR/unknown-state"; expected=81 ;;
      esac
      : > "$TEMP_DIR/pmset-calls"
      assert_exit "$expected" "$TEST_BIN" "$action"
      if (( expected != 0 )); then
        [[ ! -s "$TEMP_DIR/pmset-calls" ]] || fail "Rejected $live_state state changed power"
        if (( owned )); then
          [[ -s "$state_dir/session-token" ]] || fail 'Failure lost ownership'
        else
          [[ ! -e "$state_dir/session-token" ]] || fail 'Failure created ownership'
        fi
      else
        [[ ! -e "$state_dir/session-token" ]] || fail 'Verified restoration left ownership'
        assert_sleep_disabled 0
      fi
    done
  done
done
/bin/rm -f "$TEMP_DIR/unknown-state" "$state_dir/session-token"
print -r -- 0 > "$TEMP_DIR/sleep-disabled"

# Automatic cutoffs run in a separate process. Wait for the observable result,
# not a fixed 1–2 second scheduling assumption on a busy machine.
wait_until() {
  local cutoff=$(( SECONDS + 15 ))
  until "$@"; do
    if (( SECONDS >= cutoff )); then
      [[ -r "${TEST_HOME}/Library/Application Support/LidAwake/monitor.log" ]] &&
        /bin/cat "${TEST_HOME}/Library/Application Support/LidAwake/monitor.log" >&2
      fail "timed out waiting for: $*"
    fi
    /bin/sleep 0.1
  done
}

monitor_finished() {
  [[ "$(/bin/cat "${TEMP_DIR}/sleep-disabled")" == 0 &&
     ! -e "${TEST_HOME}/Library/Application Support/LidAwake/session-token" ]]
}

restore_failure_notified() {
  /usr/bin/grep -q '解除に失敗' "${TEMP_DIR}/notifications"
}

# Unlimited skips the expired-zero deadline but keeps battery and manual stops.
print 'AC Power' > "$TEMP_DIR/power-source"
print 20 > "$TEMP_DIR/battery-percent"
"$TEST_BIN" _start --minutes 0 --min-battery 30 >/dev/null
[[ "$(/usr/bin/awk -F= '$1 == "deadline" {print $2}' "$state_dir/session.env")" == 0 ]] || fail 'Unlimited deadline not saved'
/bin/sleep 0.5
assert_sleep_disabled 1
"$TEST_BIN" status | /usr/bin/grep -q '時間無制限' || fail 'Unlimited status missing'
print 'Battery Power' > "$TEMP_DIR/power-source"
wait_until monitor_finished
assert_exit 86 "$TEST_BIN" _start --minutes 0 --min-battery 30
print 80 > "$TEMP_DIR/battery-percent"
"$TEST_BIN" _start --minutes 0 --min-battery 30 >/dev/null
assert_exit 0 "$TEST_BIN" stop
assert_sleep_disabled 0

"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
assert_sleep_disabled 1
"$TEST_BIN" status | /usr/bin/grep -q '^有効:' || fail "status did not report active"
"$TEST_BIN" stop >/dev/null
assert_sleep_disabled 0

# Low battery is allowed on AC, including later monitor checks. Disconnecting
# AC must then apply the same cutoff without restarting the session.
print -r -- "AC Power" > "${TEMP_DIR}/power-source"
print -r -- "20" > "${TEMP_DIR}/battery-percent"
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
: > "${TEMP_DIR}/power-checks"
wait_until /usr/bin/grep -q '^AC Power:20$' "${TEMP_DIR}/power-checks"
assert_sleep_disabled 1
print -r -- "Battery Power" > "${TEMP_DIR}/power-source"
wait_until monitor_finished
assert_sleep_disabled 0
print -r -- "80" > "${TEMP_DIR}/battery-percent"

"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
first_pid=$(/bin/cat "${TEST_HOME}/Library/Application Support/LidAwake/monitor-pid")
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
second_pid=$(/bin/cat "${TEST_HOME}/Library/Application Support/LidAwake/monitor-pid")
assert_sleep_disabled 1
[[ "$first_pid" != "$second_pid" ]] || fail "start did not refresh the active session"
"$TEST_BIN" stop >/dev/null
assert_sleep_disabled 0

"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
# Regression: even a valid cutoff can take longer than the former two-second
# assertion. Deliberately delay the mocked restore without changing real power.
touch "${TEMP_DIR}/slow-restore"
print -r -- "20" > "${TEMP_DIR}/battery-percent"
wait_until monitor_finished
/bin/rm "${TEMP_DIR}/slow-restore"
assert_sleep_disabled 0
"$TEST_BIN" status | /usr/bin/grep -q '^無効:' || fail "low-battery monitor did not stop"

token=$(/usr/bin/uuidgen)
/bin/mkdir -p "$state_dir"
print -r -- "$token" > "${state_dir}/session-token"
print -r -- "1" > "${TEMP_DIR}/sleep-disabled"
print -r -- "AC Power" > "${TEMP_DIR}/power-source"
"$TEST_BIN" _monitor "$token" "$(( $(/bin/date +%s) - 1 ))" 30
assert_sleep_disabled 0
print -r -- "Battery Power" > "${TEMP_DIR}/power-source"

print -r -- "1" > "${TEMP_DIR}/sleep-disabled"
if "$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null 2>&1; then
  fail "foreign disablesleep state was not rejected"
fi
print -r -- "0" > "${TEMP_DIR}/sleep-disabled"

# A stop without ownership must not change a foreign setting.
print -r -- "1" > "${TEMP_DIR}/sleep-disabled"
assert_exit 85 "$TEST_BIN" stop
assert_sleep_disabled 1
print -r -- "0" > "${TEMP_DIR}/sleep-disabled"
print -r -- "80" > "${TEMP_DIR}/battery-percent"

# A failed manual stop retains both ownership and the running monitor.
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
saved_token=$(/bin/cat "${state_dir}/session-token")
touch "${TEMP_DIR}/fail-restore"
if "$TEST_BIN" stop >/dev/null 2>&1; then
  fail "stop succeeded despite a failed restore"
fi
assert_sleep_disabled 1
[[ "$(/bin/cat "${state_dir}/session-token")" == "$saved_token" ]] || fail "lost recovery token"
[[ -s "${state_dir}/session.env" && -s "${state_dir}/monitor-pid" ]] || fail "lost recovery metadata"
if "$TEST_BIN" _recover >/dev/null 2>&1; then
  fail "login recovery succeeded despite a failed restore"
fi
[[ "$(/bin/cat "${state_dir}/session-token")" == "$saved_token" ]] || fail "login recovery lost ownership"

# An uninstall failure must stop before any removal/system command.
/bin/mkdir -p "${TEMP_DIR}/uninstall-project/bin"
/bin/cp "$TEST_BIN" "${TEMP_DIR}/uninstall-project/bin/lid-awake"
cat > "${MOCK_DIR}/unexpected-removal" <<'MOCK_REMOVE'
#!/bin/zsh -f
print -r -- "$*" >> "${LID_AWAKE_TEST_ROOT}/unexpected-removal"
exit 99
MOCK_REMOVE
/bin/chmod 755 "${MOCK_DIR}/unexpected-removal"
python3 - "$PROJECT_DIR/runtime/uninstall.sh" "$TEMP_DIR/uninstall-project/uninstall.sh" "$MOCK_DIR/unexpected-removal" <<'PY_FIXTURE'
from pathlib import Path
import shlex, sys
body = Path(sys.argv[1]).read_text().replace('${HOME}', '${TEST_HOME}')
for command in ['/bin/rm', '/bin/rmdir', '/bin/launchctl']:
    body = body.replace(command + ' ', shlex.quote(sys.argv[3]) + ' ')
Path(sys.argv[2]).write_text(body)
PY_FIXTURE
if /bin/zsh -f "${TEMP_DIR}/uninstall-project/uninstall.sh" > "${TEMP_DIR}/uninstall-result" 2>&1; then
  fail "uninstall succeeded despite a failed restore"
fi
/usr/bin/grep -q 'アンインストールを中断' "${TEMP_DIR}/uninstall-result" || fail "uninstall did not reach restore guard"
[[ ! -e "${TEMP_DIR}/unexpected-removal" ]] || fail "uninstall attempted removal after failed restore"
[[ -s "${state_dir}/session-token" ]] || fail "uninstall removed recovery state"

# The monitor reports failure and retries; it must not announce success early.
: > "${TEMP_DIR}/notifications"
print -r -- "20" > "${TEMP_DIR}/battery-percent"
wait_until restore_failure_notified
assert_sleep_disabled 1
[[ -s "${state_dir}/session-token" ]] || fail "monitor removed token on failure"
/usr/bin/grep -q '解除に失敗' "${TEMP_DIR}/notifications" || fail "missing restore failure notification"
if /usr/bin/grep -q '通常のスリープ動作に戻しました' "${TEMP_DIR}/notifications"; then
  fail "monitor falsely reported restored sleep"
fi
/bin/rm "${TEMP_DIR}/fail-restore"
wait_until monitor_finished
assert_sleep_disabled 0
[[ ! -e "${state_dir}/session-token" ]] || fail "monitor did not finish recovery"

# An unreadable state cannot be modified; the monitor retains its stop request
# and retries after state reads become available again.
print -r -- "80" > "${TEMP_DIR}/battery-percent"
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
touch "${TEMP_DIR}/unknown-state"
: > "${TEMP_DIR}/notifications"
: > "${TEMP_DIR}/pmset-calls"
if "$TEST_BIN" stop >/dev/null 2>&1; then
  fail "stop accepted an unreadable live state"
fi
[[ -s "${state_dir}/session-token" ]] || fail "unverified restore lost recovery token"
wait_until restore_failure_notified
[[ ! -s "${TEMP_DIR}/pmset-calls" ]] || fail "Unknown state caused a power change"
/bin/rm "${TEMP_DIR}/unknown-state"
wait_until monitor_finished

# Even a successful command cannot clear ownership if the post-write read fails.
print -r -- fixture > "${state_dir}/session-token"
print -r -- 1 > "${TEMP_DIR}/sleep-disabled"
touch "${TEMP_DIR}/unknown-after-restore"
assert_exit 81 "$TEST_BIN" stop
[[ -s "${state_dir}/session-token" ]] || fail 'Unverified post-write state lost ownership'
/bin/rm "${TEMP_DIR}/unknown-after-restore" "${TEMP_DIR}/unknown-state"
"$TEST_BIN" stop >/dev/null

# Starts serialize, and only the last session's monitor retains ownership.
"$TEST_BIN" _start --minutes 1 --min-battery 30 > "${TEMP_DIR}/start-1" 2>&1 &
start_one=$!
"$TEST_BIN" _start --minutes 1 --min-battery 30 > "${TEMP_DIR}/start-2" 2>&1 &
start_two=$!
successes=0
if wait "$start_one"; then successes=$((successes + 1)); fi
if wait "$start_two"; then successes=$((successes + 1)); fi
[[ "$successes" == 2 ]] || fail "serialized starts produced ${successes} successful sessions"
"$TEST_BIN" status | /usr/bin/grep -q '^有効:' || fail "concurrent start lost monitor"
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
/bin/sleep 1
assert_sleep_disabled 1
"$TEST_BIN" status | /usr/bin/grep -q '^有効:' || fail "old monitor affected replacement session"
"$TEST_BIN" stop >/dev/null
"$TEST_BIN" --help >/dev/null

# Login recovery shares the ownership-aware stop path, without authorization.
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
"$TEST_BIN" _recover >/dev/null
assert_sleep_disabled 0
for state_file in session-token session.env monitor-pid; do
  [[ ! -e "${state_dir}/${state_file}" ]] || fail "recovery left stale ${state_file}"
done
print -r -- "1" > "${TEMP_DIR}/sleep-disabled"
assert_exit 85 "$TEST_BIN" _recover
assert_sleep_disabled 1
print -r -- "0" > "${TEMP_DIR}/sleep-disabled"

# Explicit recovery can bypass broken sudoers, but only for our own session.
cat > "${MOCK_DIR}/authorizer" <<'MOCK_AUTH'
#!/bin/zsh -f
[[ "$1" == --authorize-restore && $# == 1 ]] || exit 99
print -r -- "$*" >> "${LID_AWAKE_TEST_ROOT}/authorization-calls"
[[ ! -e "${LID_AWAKE_TEST_ROOT}/cancel-authorization" ]] || exit 82
[[ ! -e "${LID_AWAKE_TEST_ROOT}/false-authorization-success" ]] || exit 0
print -r -- 0 > "${LID_AWAKE_TEST_ROOT}/sleep-disabled"
MOCK_AUTH
/bin/chmod 755 "${MOCK_DIR}/authorizer"
export LID_AWAKE_AUTHORIZER="${MOCK_DIR}/authorizer"
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
touch "${TEMP_DIR}/fail-restore"
if "$TEST_BIN" stop >/dev/null 2>&1; then fail 'Broken permission stop succeeded'; fi
[[ ! -e "${TEMP_DIR}/authorization-calls" ]] || fail 'Ordinary stop requested authorization'
touch "${TEMP_DIR}/cancel-authorization"
if "$TEST_BIN" recover >/dev/null 2>&1; then fail 'Cancelled recovery succeeded'; fi
[[ -s "${state_dir}/session-token" ]] || fail 'Cancellation lost recovery ownership'
assert_sleep_disabled 1
/bin/rm "${TEMP_DIR}/cancel-authorization"
touch "${TEMP_DIR}/false-authorization-success"
if "$TEST_BIN" recover >/dev/null 2>&1; then fail 'Unverified authorized recovery succeeded'; fi
[[ -s "${state_dir}/session-token" ]] || fail 'Unverified recovery lost ownership'
/bin/rm "${TEMP_DIR}/false-authorization-success"
"$TEST_BIN" recover >/dev/null
assert_sleep_disabled 0
[[ ! -e "${state_dir}/session-token" ]] || fail 'Recovery left ownership behind'
# Normal stop now succeeds even while the permission remains broken: app can quit.
"$TEST_BIN" stop >/dev/null
/bin/rm "${TEMP_DIR}/authorization-calls"
print -r -- 1 > "${TEMP_DIR}/sleep-disabled"
assert_exit 85 "$TEST_BIN" recover
assert_sleep_disabled 1
[[ ! -e "${TEMP_DIR}/authorization-calls" ]] || fail 'Recovery touched a foreign session'
print -r -- 0 > "${TEMP_DIR}/sleep-disabled"
/bin/rm "${TEMP_DIR}/fail-restore"

# Invalid refresh arguments must leave the active session untouched.
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
saved_token=$(/bin/cat "${state_dir}/session-token")
if "$TEST_BIN" _start --minutes -1 --min-battery 30 >/dev/null 2>&1; then fail 'Invalid refresh accepted'; fi
[[ "$(/bin/cat "${state_dir}/session-token")" == "$saved_token" ]] || fail 'Invalid refresh replaced active session'
"$TEST_BIN" stop >/dev/null

# Manual external restoration also allows cleanup without working sudoers.
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
touch "${TEMP_DIR}/fail-restore"
print -r -- 0 > "${TEMP_DIR}/sleep-disabled"
"$TEST_BIN" stop >/dev/null
[[ ! -e "${state_dir}/session-token" ]] || fail 'External recovery left stale ownership'
/bin/rm "${TEMP_DIR}/fail-restore"
assert_exit 64 "$TEST_BIN" _start --minutes -1 --min-battery 30
print -r -- 1 > "$TEMP_DIR/sleep-disabled"
assert_exit 85 "$TEST_BIN" _start --minutes 1 --min-battery 30
print -r -- 0 > "$TEMP_DIR/sleep-disabled"
touch "$TEMP_DIR/fail-permission"
assert_exit 78 "$TEST_BIN" _start --minutes 1 --min-battery 30
/bin/rm "$TEMP_DIR/fail-permission"
print -r -- 20 > "$TEMP_DIR/battery-percent"
assert_exit 86 "$TEST_BIN" _start --minutes 1 --min-battery 30
print -r -- 80 > "$TEMP_DIR/battery-percent"
"$TEST_BIN" _start --minutes 1 --min-battery 30 >/dev/null
touch "$TEMP_DIR/fail-restore"
assert_exit 80 "$TEST_BIN" stop
touch "$TEMP_DIR/cancel-authorization"
assert_exit 82 "$TEST_BIN" recover
/bin/rm "$TEMP_DIR/cancel-authorization" "$TEMP_DIR/fail-restore"
touch "$TEMP_DIR/unknown-state"
assert_exit 81 "$TEST_BIN" stop
/bin/rm "$TEMP_DIR/unknown-state"
"$TEST_BIN" stop >/dev/null
print -- "PASS: cutoffs, ownership, failure retention, uninstall abort, serialized refresh, login recovery, explicit recovery, cancellation, external recovery, and stable exit codes"
