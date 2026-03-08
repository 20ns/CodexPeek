#!/bin/zsh
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="CodexPeek"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$ROOT_DIR/.build/${APP_NAME}.app"

mkdir -p "$DIST_DIR"

"$ROOT_DIR/Scripts/build_app.sh"

rm -f "$DIST_DIR/${APP_NAME}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/${APP_NAME}.zip"

echo "Built $DIST_DIR/${APP_NAME}.zip"
