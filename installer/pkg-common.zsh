# Shared by Installer scripts. Product metadata is generated into the signed PKG.
source "${${(%):-%x}:A:h}/product.zsh"
pkg_fail() { print -u2 -- "${LA_APP_NAME}: $*"; return 1; }

# Installer consumes success/failure; stable stage codes go in its diagnostic log.
pkg_step() {
  local code="$1"
  shift
  "$@" && return 0
  local result=$?
  print -u2 -- "${LA_APP_NAME} [$code]: $1 に失敗しました（終了値: $result）。"
  return "$result"
}

pkg_validate_user() {
  [[ -n "$1" && "$1" != *[^A-Za-z0-9._-]* && "$1" != root && "$1" != loginwindow && "$1" != _mbsetupuser ]] ||
    { pkg_fail 'ログイン中のユーザーを確認できません。'; return 1; }
  [[ "$2" == <-> && "$2" -ge 501 ]] ||
    { pkg_fail '通常のユーザーでログインして実行してください。'; return 1; }
}

pkg_require_root_and_volume() {
  [[ "$EUID" == 0 ]] || { pkg_fail 'Installerの管理者認証が必要です。'; return 1; }
  [[ "$1" == / ]] || { pkg_fail '起動ディスク以外にはインストールできません。'; return 1; }
}

pkg_resolve_user() {
  pkg_user=$(/usr/bin/stat -f %Su /dev/console) || return 1
  pkg_uid=$(/usr/bin/stat -f %u /dev/console) || return 1
  pkg_validate_user "$pkg_user" "$pkg_uid" || return 1
  [[ "$(/usr/bin/id -u "$pkg_user")" == "$pkg_uid" ]] || return 1
}

pkg_require_app_stopped() {
  # Escape regex characters so the product name is matched literally.
  local task_pattern
  task_pattern=$(print -r -- "$LA_APP_NAME" | /usr/bin/sed 's/[][\\.^$*+?(){}|]/\\&/g')
  if /usr/bin/pgrep -x "$task_pattern" >/dev/null; then
    pkg_fail "${LA_APP_NAME}を終了してから、インストーラーを再実行してください。"
    return 1
  fi
}

pkg_pin_user() {
  [[ ! -L "$1" ]] || return 1
  (umask 077; print -r -- "$pkg_user $pkg_uid" > "$1")
}

pkg_check_pinned_user() {
  local pinned_user pinned_uid extra
  [[ -f "$1" && ! -L "$1" && "$(/usr/bin/stat -f %u "$1")" == 0 ]] || return 1
  read -r pinned_user pinned_uid extra < "$1" || return 1
  pkg_validate_user "$pinned_user" "$pinned_uid" || return 1
  [[ -z "$extra" && "$pinned_user" == "$pkg_user" && "$pinned_uid" == "$pkg_uid" ]] || {
    pkg_fail 'インストール中にログインユーザーが変わりました。再実行してください。'; return 1
  }
}

pkg_validate_app() {
  local app="$LA_APP_PATH"
  [[ -d "$app" && ! -L "$app" && "$(/usr/bin/stat -f %u "$app")" == 0 ]] || return 1
  [[ "$(/usr/bin/stat -f %u "$app/Contents/MacOS/$LA_APP_NAME")" == 0 ]] || return 1
  /usr/bin/codesign --verify --deep --strict \
    -R "$LA_SIGNING_REQUIREMENT" "$app"
}

pkg_rule() {
  pkg_validate_user "$1" "$2" || return 1
  print -r -- "$1 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
}

pkg_install_rule() {
  local task_rule_dir target="/etc/sudoers.d/lid-awake-$pkg_user"
  [[ ! -L "$target" ]] || return 1
  task_rule_dir=$(/usr/bin/mktemp -d /private/tmp/lid-awake-pkg-rule.XXXXXX) || return 1
  {
    pkg_rule "$pkg_user" "$pkg_uid" > "$task_rule_dir/rule" || return 1
    /usr/sbin/visudo -cf "$task_rule_dir/rule" || return 1
    /bin/mkdir -p /etc/sudoers.d || return 1
    /usr/bin/install -o root -g wheel -m 440 "$task_rule_dir/rule" "$target"
  } always {
    /bin/rm -rf "$task_rule_dir"
  }
}

pkg_user_setup() {
  # Never write to a user's home as root, or run user-writable scripts as root.
  # sudo -H derives the target user's home from the account database.
  /bin/launchctl asuser "$pkg_uid" /usr/bin/sudo -H -u "$pkg_user" \
    /bin/zsh -f -- "$LA_APP_PATH/Contents/Resources/runtime/setup-runtime.sh"
}

pkg_open_settings() {
  # A user switch during setup must not open the app in another user's session.
  pkg_resolve_user || return 1
  pkg_check_pinned_user "$1" || return 1
  # Use the logged-in user's GUI session and credentials, never root. A normal
  # LaunchServices launch opens settings; it does not start sleep prevention.
  /bin/launchctl asuser "$pkg_uid" /usr/bin/sudo -H -u "$pkg_user" \
    /usr/bin/open "$LA_APP_PATH"
}
