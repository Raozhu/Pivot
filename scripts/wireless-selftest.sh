#!/bin/bash
# 无线链路的本机回环自测（不需要 iPad）。
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/wireless-selftest Sources/Shared/Wire.swift Sources/Shared/Pairing.swift scripts/wireless-selftest/main.swift 2>&1 | grep -E "error" | head
build/wireless-selftest
