#!/bin/sh
# The text blob's pure rules (app/BlobRules.swift, app/BlobPanel.swift) against tests/BlobTests.swift. Run by the GitHub workflow.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -parse-as-library app/BlobRules.swift app/BlobPanel.swift tests/BlobTests.swift -o build/blob_tests
build/blob_tests
