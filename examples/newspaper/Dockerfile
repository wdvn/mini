FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    curl \
    python3 \
    ca-certificates \
    jq \
    python3-pip \
    cron \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# Set timezone to Vietnam
ENV TZ=Asia/Ho_Chi_Minh
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN pip3 install "mcp[cli]" requests --break-system-packages

WORKDIR /app

# Copy toàn bộ files trong thư mục hiện tại vào /app (bao gồm mini, run.sh, v.v)
COPY . .

RUN chmod +x run.sh mini || true

# Tạo script wrapper để cron có đầy đủ env vars
RUN echo '#!/bin/bash\n\
cd /app\n\
. /app/.cronenv\n\
./run.sh >> /var/log/newspaper-cron.log 2>&1\n' > /app/cron-wrapper.sh \
    && chmod +x /app/cron-wrapper.sh

# Crontab: 5h sáng giờ Việt Nam mỗi ngày
RUN echo "0 5 * * * /app/cron-wrapper.sh" > /etc/cron.d/newspaper \
    && chmod 0644 /etc/cron.d/newspaper \
    && crontab /etc/cron.d/newspaper

# Khởi động bằng entrypoint script
RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]