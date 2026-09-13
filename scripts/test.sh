#!/bin/zsh -f
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
readonly task_suite="${1:-all}"
case "$task_suite" in
  all|shell|swift) ;;
  *) print -u2 'Usage: scripts/test.sh [all|shell|swift]'; exit 64 ;;
esac
(( $# <= 1 )) || { print -u2 'Too many arguments'; exit 64; }
[[ "$(/usr/bin/uname -s)" == Darwin ]] || { print -u2 'Tests require macOS.'; exit 1; }
command -v python3 >/dev/null || { print -u2 'Python 3 is required.'; exit 1; }

if [[ "$task_suite" != shell ]]; then
  command -v xcodegen >/dev/null || { print -u2 'XcodeGen is required.'; exit 1; }
  if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 || ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    print -u2 'Select a full Xcode installation with DEVELOPER_DIR or xcode-select. Command Line Tools alone cannot run Swift tests.'
    exit 1
  fi
fi

if [[ "$task_suite" != swift ]]; then
  python3 Tests/Scripts/test-configure.py
  for task_script in Tests/Scripts/test-*.zsh; do
    print -- "Running $task_script"
    /bin/zsh -f "$task_script"
  done
fi

if [[ "$task_suite" != shell ]]; then
  xcodegen generate
  /usr/bin/xcodebuild -project LidAwake.xcodeproj -scheme LidAwake -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath .build-tests test
fi
