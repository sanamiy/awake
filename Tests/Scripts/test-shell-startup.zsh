#!/bin/zsh -f
# Use a private startup directory and a no-op body. Never execute application code.
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
readonly task_root=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$task_root"' EXIT
export ZDOTDIR="$task_root/startup"
export STARTUP_MARKER="$task_root/marker"
/bin/mkdir -p "$ZDOTDIR"
print -r -- 'print hit >> "$STARTUP_MARKER"' > "$ZDOTDIR/.zshenv"
# Positive control proves this macOS zsh would otherwise read the injected file.
/bin/zsh -c ':'
[[ -s "$STARTUP_MARKER" ]] || { print -u2 'FAIL: startup-file positive control'; exit 1; }
/bin/rm "$STARTUP_MARKER"
for source_script in runtime/bin/lid-awake runtime/setup-runtime.sh runtime/uninstall.sh installer/preinstall installer/postinstall; do
  /usr/bin/head -n 1 "$PROJECT_DIR/$source_script" > "$task_root/probe"
  print -r -- 'exit 0' >> "$task_root/probe"
  /bin/chmod 755 "$task_root/probe"
  "$task_root/probe"
  [[ ! -e "$STARTUP_MARKER" ]] || { print -u2 "FAIL: $source_script reads user startup code"; exit 1; }
done
# The detached monitor is another interpreter entry, not covered by Swift's flags.
/usr/bin/grep -Fq '"$NOHUP" /bin/zsh -f -- "$SCRIPT_PATH" _monitor' "$PROJECT_DIR/runtime/bin/lid-awake" || {
  print -u2 'FAIL: detached monitor must disable startup files'; exit 1
}
/usr/bin/grep -Fq '/bin/zsh -f -- ' "$PROJECT_DIR/installer/pkg-common.zsh" || {
  print -u2 'FAIL: Installer user stage must disable startup files'; exit 1
}
print 'PASS: runtime and installer shebangs ignore user startup files (positive control passed)'
