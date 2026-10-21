#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc "$REPO/MacTV_MacApp/MacTV_MacApp/RemoteWire.swift" "$REPO/protocol/tests/WireTests.swift" -o "$TASK_TMP/wire-tests"
"$TASK_TMP/wire-tests"
