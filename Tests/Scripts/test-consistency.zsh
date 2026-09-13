#!/bin/zsh -f
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
cd "$PROJECT_DIR"

fail() { print -u2 -- "FAIL: $*"; exit 1; }
require_text() { /usr/bin/grep -Fq -- "$1" "$2" || fail "Missing contract in $2: $1"; }

# Distribution configuration checks only. Runtime behavior is covered by
# Swift and CLI tests; source spelling and UI wording are not contracts.
if /usr/bin/grep -q 'NSAppleEventsUsageDescription' App/Info.plist; then
  fail 'Obsolete Apple Events privacy key returned'
fi
if /usr/bin/grep -q 'CODE_SIGN_ENTITLEMENTS' project.yml; then
  fail 'Review any newly introduced signing entitlements before publishing'
fi
require_text '.build*/' .gitignore
require_text 'experiments/' .gitignore
require_text '*.p12' .gitignore
require_text '*.pfx' .gitignore
print 'PASS: distribution configuration and publication exclusions'
