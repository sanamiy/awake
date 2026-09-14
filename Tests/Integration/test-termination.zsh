#!/bin/zsh -f
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h:h}"
readonly task_directory=$(/usr/bin/mktemp -d /tmp/awake-termination-test.XXXXXX)
trap '/bin/rm -rf "$task_directory"' EXIT
task_sources=("$PROJECT_DIR"/App/*.swift)
task_sources=("${(@)task_sources:#*/AppEntry.swift}")
# Compile the real app sources, replacing only the entry point and OS dependencies.
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 "${task_sources[@]}" \
  "$PROJECT_DIR/Tests/Integration/TerminationProbe.swift" -o "$task_directory/probe"
"$task_directory/probe" "$task_directory"
"$task_directory/probe" "$task_directory" --fail-first
