#!/bin/zsh -f
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
readonly task_generated=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$task_generated"' EXIT
python3 "$PROJECT_DIR/scripts/configure.py" --installer-dir "$task_generated"
source "$task_generated/scripts/pkg-common.zsh"

assert_equal() { [[ "$1" == "$2" ]] || { print -u2 -- "FAIL: $1 != $2"; exit 1; }; }
# Check both the source Distribution and, optionally, the one expanded from a
# built PKG. Scripts alone cannot make Installer show an actionable quit prompt.
readonly distribution="${1:-$task_generated/Distribution.xml}"
/usr/bin/xmllint --noout "$distribution"
assert_equal "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/options/@hostArchitectures)' "$distribution")" "${LA_ARCHS// /,}"
assert_equal "$(/usr/bin/xmllint --xpath 'string(/installer-gui-script/allowed-os-versions/os-version/@min)' "$distribution")" "$LA_MIN_OS"
assert_equal "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/pkg-ref[@id="'"$LA_PACKAGE_ID"'"]/must-close/app[@id="'"$LA_BUNDLE_ID"'"])' "$distribution")" 1
assert_equal "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/choice[@id="main"]/pkg-ref[@id="'"$LA_PACKAGE_ID"'"])' "$distribution")" 1
assert_equal "$(/usr/bin/xmllint --xpath 'count(/installer-gui-script/pkg-ref[@id="'"$LA_PACKAGE_ID"'"][text()[normalize-space(.) != ""]])' "$distribution")" 1
assert_equal "$(pkg_rule test-user 501)" 'test-user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1'
for username in '' root loginwindow _mbsetupuser '../root' 'bad name' "bad'; command" $'bad\nname'; do
  if pkg_validate_user "$username" 501 2>/dev/null; then print -u2 'Unsafe username accepted'; exit 1; fi
done
for uid in '' 0 500 invalid '501; command'; do
  if pkg_validate_user test-user "$uid" 2>/dev/null; then print -u2 'Unsafe UID accepted'; exit 1; fi
done

# Source the real entry points, then replace every system read/write boundary.
# No installer, sudo, launchctl, power-control or Trash operation runs in tests.
check_preinstall() (
  source "$task_generated/scripts/preinstall"
  local fail_step="$1" expected="$2" result
  local -a calls=()
  step() { calls+=("$1"); [[ "$fail_step" != "$1" ]]; }
  pkg_require_root_and_volume() { assert_equal "$1" /; step root; }
  pkg_resolve_user() { step user; }
  pkg_require_app_stopped() { step stopped; }
  pkg_pin_user() { [[ "$1" == */install-target ]] || exit 1; step pin; }
  if preinstall_main package /Applications / 2>/dev/null; then result=success; else result=failure; fi
  assert_equal "${(j:,:)calls}" "$expected"
  if [[ "$fail_step" == none ]]; then assert_equal "$result" success; else assert_equal "$result" failure; fi
)
check_preinstall none root,user,stopped,pin
check_preinstall root root
check_preinstall user root,user
check_preinstall stopped root,user,stopped
check_preinstall pin root,user,stopped,pin

check_postinstall() (
  source "$task_generated/scripts/postinstall"
  local fail_step="$1" expected="$2" result
  local -a calls=()
  step() { calls+=("$1"); [[ "$fail_step" != "$1" ]]; }
  pkg_require_root_and_volume() { assert_equal "$1" /; step root; }
  pkg_resolve_user() { step user; }
  pkg_check_pinned_user() { step pinned; }
  pkg_require_app_stopped() { step stopped; }
  pkg_validate_app() { step signature; }
  pkg_install_rule() { step rule; }
  pkg_user_setup() { step setup; }
  pkg_open_settings() { [[ "$1" == */install-target ]] || exit 1; step launch; }
  if postinstall_main package /Applications / >/dev/null 2>&1; then result=success; else result=failure; fi
  assert_equal "${(j:,:)calls}" "$expected"
  if [[ "$fail_step" == none || "$fail_step" == launch ]]; then assert_equal "$result" success; else assert_equal "$result" failure; fi
)
check_postinstall none root,user,pinned,stopped,signature,rule,setup,launch
check_postinstall launch root,user,pinned,stopped,signature,rule,setup,launch
check_postinstall root root
check_postinstall user root,user
check_postinstall pinned root,user,pinned
check_postinstall stopped root,user,pinned,stopped
check_postinstall signature root,user,pinned,stopped,signature
check_postinstall rule root,user,pinned,stopped,signature,rule
check_postinstall setup root,user,pinned,stopped,signature,rule,setup

# Exercise the real launch wrapper while intercepting the OS boundary. Verify
# the user/session checks precede launch and that no privileged app is spawned.
check_settings_launch() (
  local fail_step="$1" expected="$2" result
  local pkg_user=test-user pkg_uid=501
  local -a calls=()
  step() { calls+=("$1"); [[ "$fail_step" != "$1" ]]; }
  pkg_resolve_user() { step user; }
  pkg_check_pinned_user() { assert_equal "$1" /fixture/install-target; step pinned; }
  local task_body="${functions[pkg_open_settings]}"
  task_body="${task_body//\/bin\/launchctl/fake_launchctl}"
  functions[pkg_open_settings]="$task_body"
  fake_launchctl() {
    local -a expected_args=(asuser 501 /usr/bin/sudo -H -u test-user /usr/bin/open "$LA_APP_PATH")
    assert_equal "$#" "${#expected_args}"
    local index
    for (( index=1; index <= $#; index++ )); do
      assert_equal "${@[index]}" "${expected_args[index]}"
    done
    step launch
  }
  if pkg_open_settings /fixture/install-target; then result=success; else result=failure; fi
  assert_equal "${(j:,:)calls}" "$expected"
  if [[ "$fail_step" == none ]]; then assert_equal "$result" success; else assert_equal "$result" failure; fi
)
check_settings_launch none user,pinned,launch
check_settings_launch user user
check_settings_launch pinned user,pinned
check_settings_launch launch user,pinned,launch

print 'PASS: Installer quit declaration, PKG user validation, exact permission scope, setup ordering, and every failure boundary'
