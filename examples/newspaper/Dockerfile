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

COPY bin /app/bin
COPY examples /app/examples

WORKDIR /app/examples/newspaper
RUN chmod +x run.sh

# Tạo script wrapper để cron có đầy đủ env vars
RUN echo '#!/bin/bash\n\
cd /app/examples/newspaper\n\
. /app/examples/newspaper/.cronenv\n\
./run.sh >> /var/log/newspaper-cron.log 2>&1\n' > /app/examples/newspaper/cron-wrapper.sh \
    && chmod +x /app/examples/newspaper/cron-wrapper.sh

# Crontab: 5h sáng giờ Việt Nam mỗi ngày
RUN echo "0 5 * * * /app/examples/newspaper/cron-wrapper.sh" > /etc/cron.d/newspaper \
    && chmod 0644 /etc/cron.d/newspaper \
    && crontab /etc/cron.d/newspaper

# Entrypoint: lưu env vars cho cron, rồi khởi cron daemon
COPY examples/newspaper/entrypoint.sh /app/examples/newspaper/entrypoint.sh
RUN chmod +x /app/examples/newspaper/entrypoint.sh

ENTRYPOINT ["/app/examples/newspaper/entrypoint.sh"]