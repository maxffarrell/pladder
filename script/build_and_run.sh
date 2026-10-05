#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$(realpath "$PWD/dist/Pladder.app" 2>/dev/null || printf '%s' "$PWD/dist/Pladder.app")"
# Stop only this checkout's app. Other installations stay running.
while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid"
done < <(pgrep -f "^${app}/Contents/MacOS/Pladder([[:space:]]|$)" || true)
scripts/bundle.sh
open "$(realpath "$PWD/dist/Pladder.app")"
