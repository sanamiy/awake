#!/bin/zsh -f
# Exercise the native entry point with a harmless sibling, never the power CLI.
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
readonly task_root=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$task_root"' EXIT
readonly fixture_dir="$task_root/path with spaces"
/bin/mkdir -p "$fixture_dir"
/usr/bin/xcrun clang -Wall -Wextra -Werror -Wno-unused-parameter \
  "$PROJECT_DIR/Recovery/main.c" -o "$fixture_dir/AwakeRecovery"
print '[[ $# == 1 && "$1" == _recover ]] || exit 99; exit 85' > "$fixture_dir/lid-awake"
print 'exit 98' > "$task_root/.zshenv"
run_entry() {
  local expected="$1" actual=0
  shift
  ZDOTDIR="$task_root" "$fixture_dir/AwakeRecovery" "$@" > "$task_root/output" 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || { print -u2 "Expected $expected, got $actual"; exit 1; }
}
run_entry 85
run_entry 64 start
run_entry 64 _recover
/bin/rm "$fixture_dir/lid-awake"
run_entry 127
print 'PASS: signed entry contract, fixed recovery action, startup isolation, spaced paths and propagated failures'
