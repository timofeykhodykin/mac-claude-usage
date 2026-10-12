#!/bin/bash
# `swift test` with only the Command Line Tools needs the Testing framework path spelled out.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
if [[ -d "$FW/Testing.framework" ]]; then
    exec swift test -Xswiftc -F"$FW" -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
fi
exec swift test "$@"
