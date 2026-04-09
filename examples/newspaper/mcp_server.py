from mcp.server.fastmcp import FastMCP
import requests
import os
import logging
from logging.handlers import RotatingFileHandler

# ─── Logging setup ────────────────────────────────────────────────────────────
LOG_DIR = os.environ.get("MCP_LOG_DIR", "/tmp/logs")
LOG_FILE = os.path.join(LOG_DIR, "mcp_server.log")
LOG_MAX_BYTES = int(os.environ.get("MCP_LOG_MAX_BYTES", 2 * 1024 * 1024))  # 2MB
LOG_BACKUP_COUNT = int(os.environ.get("MCP_LOG_BACKUP_COUNT", 5))

os.makedirs(LOG_DIR, exist_ok=True)

logger = logging.getLogger("mcp_server")
logger.setLevel(logging.DEBUG)

formatter = logging.Formatter(
    "[%(asctime)s] %(levelname)-8s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)

# Rotating file handler
file_handler = RotatingFileHandler(
    LOG_FILE,
    maxBytes=LOG_MAX_BYTES,
    backupCount=LOG_BACKUP_COUNT,
    encoding="utf-8",
)
file_handler.setLevel(logging.DEBUG)
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)

# Stderr handler (visible in Docker logs / mini agent output)
stderr_handler = logging.StreamHandler()
stderr_handler.setLevel(logging.INFO)
stderr_handler.setFormatter(formatter)
logger.addHandler(stderr_handler)

logger.info("MCP server starting — log: %s (max %s bytes × %d backups)",
            LOG_FILE, LOG_MAX_BYTES, LOG_BACKUP_COUNT)

# ─── MCP Server ───────────────────────────────────────────────────────────────
mcp = FastMCP("wdvn_api")

@mcp.tool()
def send_report(filename: str, content: str) -> str:
    """Send the completed Hacker News daily digest report to the system API."""
    account = os.getenv("ACCOUNT", "")
    password = os.getenv("PASSWORD", "")

    logger.info("send_report called — filename=%s, content_length=%d", filename, len(content))
    logger.debug("content preview: %.500s...", content)
    if not filename:
        filename = 'newspaper_{}.md'.format(datetime.now().strftime("%Y-%m-%d"))
    try:
        response = requests.post(
            "https://me.thewdvn.cc/api/mcp/news",
            json={
                "file_name": filename,
                "content": content,
            },
            auth=(account, password) if account else None,
            timeout=30
        )
        result = f"Status: {response.status_code}, Response: {response.text}"

        if response.ok:
            logger.info("Report sent OK — status=%d, filename=%s", response.status_code, filename)
        else:
            logger.warning("Report failed — status=%d, body=%s", response.status_code, response.text[:500])

        return result
    except Exception as e:
        logger.error("send_report exception: %s", e, exc_info=True)
        return f"Failed to send report: {str(e)}"

if __name__ == "__main__":
    logger.info("Starting MCP stdio transport...")
    mcp.run()
