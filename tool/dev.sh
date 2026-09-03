#!/usr/bin/env bash
# Flutter Web 開發伺服器＋存檔自動 hot reload。
# 用法：tool/dev.sh [port]；停止：kill $(cat .dart_tool/dev.pid)
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-8787}"
PID_FILE="$PWD/.dart_tool/dev.pid"
mkdir -p .dart_tool
flutter run -d web-server --web-port "$PORT" --web-hostname 127.0.0.1 --pid-file "$PID_FILE" &
FLUTTER_PID=$!
# 等 pid 檔出現後開始監看 lib/，存檔就送 SIGUSR1（hot reload）
( while [ ! -f "$PID_FILE" ]; do sleep 1; done
  fswatch -o -l 0.5 lib | while read -r _; do kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null || true; done ) &
WATCH_PID=$!
trap 'kill $WATCH_PID 2>/dev/null; kill $FLUTTER_PID 2>/dev/null' EXIT
wait $FLUTTER_PID
