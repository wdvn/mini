#!/usr/bin/env bash
# run.sh — Newspaper Agent runner
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SKILL_DIR"

echo "[newspaper] Starting agent in single mode..."

# Chạy mini-agent với single task
# Nếu đạt 50 vòng lặp (MAX_ITERATIONS), mini-agent sẽ thoát với lỗi
./mini --single ./task.md

STATUS=$?
if [ $STATUS -eq 0 ]; then
    echo "[newspaper] ✓ Agent completed successfully."
else
    echo "[newspaper] ✗ Agent failed (exit code $STATUS)."
    if [ $STATUS -eq 1 ]; then
        echo "[newspaper] NOTE: This might be due to MaxIterationsReached or a runtime crash."
    fi
    exit $STATUS
fi