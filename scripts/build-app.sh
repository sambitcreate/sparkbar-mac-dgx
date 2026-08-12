#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

BIN_DIR=$(swift build -c release --show-bin-path)
APP_DIR="$ROOT_DIR/.build/Release/SparkBar.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SparkBar" "$APP_DIR/Contents/MacOS/SparkBar"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Built $APP_DIR"
