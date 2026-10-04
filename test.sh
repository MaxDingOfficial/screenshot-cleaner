#!/bin/zsh
set -eu
SOURCE_DIR="${0:A:h}"
BUILD_WORK="$SOURCE_DIR/.build"
TEST_WORK="$BUILD_WORK/test-work"
mkdir -p "$BUILD_WORK" "$TEST_WORK"
xcrun swiftc -swift-version 5 "$SOURCE_DIR/CleanerCore.swift" "$SOURCE_DIR/CoreTests.swift" -o "$BUILD_WORK/CoreTests"
"$BUILD_WORK/CoreTests" "$TEST_WORK"
