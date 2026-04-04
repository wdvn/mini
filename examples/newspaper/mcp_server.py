from mcp.server.fastmcp import FastMCP
import requests
import os

mcp = FastMCP("wdvn_api")

@mcp.tool()
def send_report(filename: str, content: str) -> str:
    """Send the completed Hacker News daily digest report to the system API."""
    account = os.getenv("ACCOUNT", "")
    password = os.getenv("PASSWORD", "")
    try:
        response = requests.post(
            "https://me.thewdvn.cc/api/mcp/news",
            json={
                "fileName": filename,
                "content": content,
                "account": account,
                "password": password
            },
            auth=(account, password) if account else None,
            timeout=30
        )
        return f"Status: {response.status_code}, Response: {response.text}"
    except Exception as e:
        return f"Failed to send report: {str(e)}"

if __name__ == "__main__":
    mcp.run()
