#!/bin/zsh

set -euo pipefail

DEVICE_NAME="${1:-iPhone 16 Pro}"
BUNDLE_ID="com.wiktorjarochiewicz.taskboard"
SOURCE="$HOME/Library/Application Support/taskboard/boards.json"

if [[ ! -f "$SOURCE" ]]; then
    echo "No local taskboard snapshot found at: $SOURCE" >&2
    exit 1
fi

DATA_CONTAINER="$(xcrun simctl get_app_container "$DEVICE_NAME" "$BUNDLE_ID" data)"
DESTINATION_DIR="$DATA_CONTAINER/Library/Application Support/taskboard"

xcrun simctl terminate "$DEVICE_NAME" "$BUNDLE_ID" 2>/dev/null || true
mkdir -p "$DESTINATION_DIR"
cp "$SOURCE" "$DESTINATION_DIR/boards.json"
xcrun simctl launch "$DEVICE_NAME" "$BUNDLE_ID"

echo "Seeded $DEVICE_NAME from the local Mac taskboard snapshot."
