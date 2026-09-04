#!/bin/bash
# iOS 打包（TestFlight 版）：一律連 Supabase prod（Mike 裁示 2026-09-04）。
# 憑證與 prod 連線資訊住 ~/mike/supabase/prod.env（不進 git）。
set -euo pipefail
cd "$(dirname "$0")/.."

. ~/mike/supabase/prod.env
STAMP=$(date +%m%d-%H%M)

flutter build ipa \
  --dart-define=SUPABASE_URL="$PROD_URL" \
  --dart-define=SUPABASE_ANON_KEY="$PROD_ANON_KEY" \
  --dart-define=BUILD_STAMP="ios-$STAMP" \
  "$@"
echo "BUILD_STAMP=ios-$STAMP"
