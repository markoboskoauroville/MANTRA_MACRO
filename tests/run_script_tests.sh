#!/bin/sh
# The language alone, no app, no screen: app/Script.swift against the fake host in tests/ScriptTests.swift.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
# v31: exact-file rename rules (same folder/extension, no overwrite).
swiftc -O -swift-version 5 -parse-as-library app/FileRename.swift tests/FileRenameTests.swift -o build/file_rename_tests
build/file_rename_tests
swiftc -O -swift-version 5 -parse-as-library app/Script.swift tests/ScriptTests.swift -o build/script_tests
build/script_tests
# v8: RECALIBRATE's coordinates (app/Coords.swift), no app needed
swiftc -O -swift-version 5 -parse-as-library app/Coords.swift tests/RecalTests.swift -o build/recal_tests
build/recal_tests
