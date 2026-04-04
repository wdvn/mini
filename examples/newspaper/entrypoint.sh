#!/bin/bash
# entrypoint.sh — Khởi tạo môi trường và chạy cron daemon
#
# Lưu tất cả env vars hiện tại vào file để cron job có thể đọc được,
# vì cron chạy trong shell riêng không thừa hưởng env từ Docker.

set -e

# Export env vars ra file cho cron wrapper sử dụng
env | grep -E '^(OPENAI_|ANTHROPIC_|MINI_|OLLAMA_|ACCOUNT|PASSWORD|TZ|PATH|HOME)' \
    | sed 's/^/export /' > /app/.cronenv

echo "[entrypoint] Timezone: $(date +%Z) ($(date))"
echo "[entrypoint] Cron schedule: 5:00 AM daily (Asia/Ho_Chi_Minh)"
echo "[entrypoint] Env vars saved to .cronenv"

# Chạy 1 lần ngay khi start (tuỳ chọn, bỏ dòng dưới nếu chỉ muốn chạy theo lịch)
if [[ "${RUN_ON_START:-false}" == "true" ]]; then
    echo "[entrypoint] RUN_ON_START=true, running now..."
    cd /app && ./run.sh || true
fi

# Khởi cron daemon foreground để container không thoát
echo "[entrypoint] Starting cron daemon..."
exec cron -f
