#!/usr/bin/env bash
# Draws every Capio screen to PNG off screen (no permissions needed) and checks the pictures. Run on the Mac after build.sh.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-build/shots}"
DATA="$(mktemp -d)"
rm -rf "$OUT"; mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
open -n --env CAPIO_DATA_DIR="$DATA" build/Capio.app --args --snapshot-dir "$OUT_ABS"
for _ in $(seq 60); do [ -f "$OUT/DONE.txt" ] || [ -f "$OUT/FAILED.txt" ] && break; sleep 1; done
rm -rf "$DATA"
[ -f "$OUT/DONE.txt" ] || { echo "snapshot did not finish: $(cat "$OUT/FAILED.txt" 2>/dev/null || echo timeout)"; exit 1; }
ls "$OUT"
echo "OCR of the export:"; sed 's/^/  /' "$OUT/4-export-ocr.txt"
