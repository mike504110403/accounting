#!/usr/bin/env bash
# release build＋注入 build 戳記（設定頁底可見，分辨快取版本用）。
set -euo pipefail
cd "$(dirname "$0")/.."
STAMP="$(date +%m%d-%H%M)"
flutter build web --release --dart-define=BUILD_STAMP="$STAMP"
echo "BUILD_STAMP=$STAMP"
