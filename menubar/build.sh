#!/bin/bash
# Builds "LLM Memory.app" from the single Swift file next to this script.
#
# Committed on purpose: a bundle assembled by hand once is a bundle nobody can
# rebuild. The Info.plist keys are load-bearing (see Info.plist.in) and the
# ad-hoc signature is what stops macOS re-prompting for permissions on every
# rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LLM Memory"
VERSION="1.0.0"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
if ! git diff --quiet 2>/dev/null; then BUILD="${BUILD}-dirty"; fi
STAGE="../build/${APP_NAME}.app"

echo "==> swiftc LLMMenu.swift"
mkdir -p ../build
swiftc -O -whole-module-optimization LLMMenu.swift -o ../build/LLMMenu

echo "==> assembling ${APP_NAME}.app  (${VERSION} ${BUILD})"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
sed -e "s/@VERSION@/${VERSION}/" -e "s/@BUILD@/${BUILD}/" \
    Info.plist.in > "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
mv ../build/LLMMenu "$STAGE/Contents/MacOS/LLMMenu"

# Ship the CLI inside the bundle as a fallback: findLLMCTL() looks in
# Contents/Resources, so the app works even if llmctl is not on PATH.
cp ../llmctl "$STAGE/Contents/Resources/llmctl"
chmod +x "$STAGE/Contents/Resources/llmctl"

echo "==> ad-hoc sign"
codesign --force --sign - --timestamp=none "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "==> done: $STAGE"
echo "    install: ./install.sh    (or drag it to /Applications)"
