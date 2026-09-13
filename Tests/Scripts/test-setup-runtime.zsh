#!/bin/zsh -f
# Exercise the actual installer user stage with all system boundaries mocked.
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
readonly task_root=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$task_root"' EXIT
export TEST_SETUP_ROOT="$task_root"
export TEST_SETUP_HOME="$task_root/user & space"
/bin/mkdir -p "$task_root/project/bin" "$task_root/mock"

cat > "$task_root/project/bin/lid-awake" <<'RUNTIME'
#!/bin/zsh -f
readonly PROGRAM_NAME="Fixture App"
readonly PROGRAM_BUNDLE_ID="example.fixture.app"
fail() { print -u2 -- "$*"; exit 1; }
acquire_lock() {
  print lock >> "$TEST_SETUP_ROOT/trace"
  [[ ! -e "$TEST_SETUP_ROOT/fail-lock" ]] || return 1
  zmodload zsh/system
  : >> "$TEST_SETUP_ROOT/operation.lock"
  zsystem flock -t 0 -f TEST_LOCK_FD "$TEST_SETUP_ROOT/operation.lock"
}
release_lock() { print release >> "$TEST_SETUP_ROOT/trace"; zsystem flock -u "$TEST_LOCK_FD"; }
stop_session() { print stop >> "$TEST_SETUP_ROOT/trace"; [[ ! -e "$TEST_SETUP_ROOT/fail-stop" ]]; }
show_status() { print status >> "$TEST_SETUP_ROOT/trace"; [[ ! -e "$TEST_SETUP_ROOT/fail-status" ]]; }
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  [[ "$1" == status ]] || exit 99
  print status >> "$TEST_SETUP_ROOT/trace"
fi
RUNTIME
cat > "$task_root/mock/sudo" <<'SUDO'
#!/bin/zsh -f
[[ "$1 $2 $3 $4 $5" == '-n -l /usr/bin/pmset -a disablesleep' ]] || exit 99
[[ ! -e "$TEST_SETUP_ROOT/fail-permission" ]]
SUDO
cat > "$task_root/mock/launchctl" <<'LAUNCH'
#!/bin/zsh -f
print -r -- "$1" >> "$TEST_SETUP_ROOT/trace"
zmodload zsh/system
if zsystem flock -t 0 -f competing_fd "$TEST_SETUP_ROOT/operation.lock"; then
  print -u2 'Installer released its operation lock before registration finished'
  exit 98
fi
[[ ! -e "$TEST_SETUP_ROOT/fail-$1" ]]
LAUNCH
/bin/chmod 755 "$task_root/mock/"* "$task_root/project/bin/lid-awake"
# Redirect every persistent location without changing the test runner's HOME.
python3 - "$PROJECT_DIR/runtime/setup-runtime.sh" "$task_root/project/setup-runtime.sh" "$task_root/mock" <<'PY_FIXTURE'
from pathlib import Path
import shlex, sys
body = Path(sys.argv[1]).read_text().replace('${HOME}', '${TEST_SETUP_HOME}')
rule = '/etc/sudoers.d/lid-awake-${USER}'
if body.count(rule) != 1:
    raise SystemExit('Cannot isolate sudoers path')
body = body.replace(rule, '${TEST_SETUP_ROOT}/rule')
for command, mock in [('/usr/bin/sudo', 'sudo'), ('/bin/launchctl', 'launchctl')]:
    if command not in body:
        raise SystemExit(f'Cannot isolate {command}')
    body = body.replace(command, shlex.quote(str(Path(sys.argv[3]) / mock)))
Path(sys.argv[2]).write_text(body)
PY_FIXTURE
run_setup() { /bin/zsh -f "$task_root/project/setup-runtime.sh" > "$task_root/output" 2>&1; }
fail() { /bin/cat "$task_root/output" >&2; print -u2 -- "FAIL: $*"; exit 1; }

if run_setup; then fail 'Missing PKG permissions accepted'; fi
[[ ! -e "$TEST_SETUP_HOME" ]] || fail 'Wrote runtime before permission check'
touch "$task_root/rule" "$task_root/fail-permission"
if run_setup; then fail 'Broken PKG permissions accepted'; fi
[[ ! -e "$TEST_SETUP_HOME" ]] || fail 'Wrote runtime before permission validation'
/bin/rm "$task_root/fail-permission"
for boundary in lock stop; do
  touch "$task_root/fail-$boundary"
  if run_setup; then fail "Ignored $boundary failure"; fi
  [[ ! -e "$TEST_SETUP_HOME" ]] || fail "Wrote runtime after $boundary failure"
  /bin/rm "$task_root/fail-$boundary"
done

: > "$task_root/trace"
run_setup || fail 'Valid install failed'
readonly agent="$TEST_SETUP_HOME/Library/LaunchAgents/dev.lid-awake.recover.plist"
[[ "$(/usr/bin/plutil -extract AssociatedBundleIdentifiers.0 raw -o - "$agent")" == example.fixture.app ]] || fail 'Recovery service is not associated with its app'
[[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$agent")" == "$TEST_SETUP_HOME/.local/bin/lid-awake" ]] || fail 'Home path was not escaped correctly'
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$agent")" == _recover ]] || fail 'Wrong recovery command'
[[ "$(/usr/bin/plutil -extract RunAtLoad raw -o - "$agent")" == true ]] || fail 'Missing RunAtLoad'
[[ "$(/usr/bin/tr '\n' ',' < "$task_root/trace")" == 'lock,stop,bootout,enable,bootstrap,print,status,release,' ]] || fail 'Wrong install ordering'
/usr/bin/cmp "$task_root/project/bin/lid-awake" "$TEST_SETUP_HOME/.local/bin/lid-awake" || fail 'Installed runtime differs'
readonly progress="$TEST_SETUP_HOME/Library/Application Support/LidAwake/uninstall-state"
/bin/mkdir -p "${progress:h}"
print readyForFinder > "$progress"
run_setup || fail 'Reinstallation failed'
[[ ! -e "$progress" ]] || fail 'Successful reinstall retained uninstall progress'
for boundary in lock stop enable bootstrap print status; do
  print cleaning > "$progress"
  touch "$task_root/fail-$boundary"
  if run_setup; then fail "Ignored $boundary failure"; fi
  [[ "$(< "$progress")" == cleaning ]] || fail "Failed $boundary reset uninstall progress"
  /bin/rm "$task_root/fail-$boundary"
done
touch "$task_root/fail-bootout"
run_setup || fail 'Absent prior job should not block registration'
[[ ! -e "$progress" ]] || fail 'Successful setup retained uninstall progress'
print 'PASS: setup permissions, lock/restore boundaries, escaped plist, ordering, reinstallation, and registration failures'
