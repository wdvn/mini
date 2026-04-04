#!/usr/bin/env bash
# run.sh — Newspaper Agent runner for mini-agent
#
# Cách dùng:
#   ./run.sh
#   ./run.sh --hn-top 30
#   ./run.sh --no-ai
#   ./run.sh --cron          # Cron mode — lưu vào ~/newspaper-digests/
#   ./run.sh --output /path/to/file.md
#
# Cron (7:00 sáng mỗi ngày):
#   0 7 * * * cd /home/mypc/projects/mini && examples/newspaper/run.sh --cron >> ~/newspaper-digests/cron.log 2>&1
#
# Biến môi trường:
#   OPENAI_COMPAT_URL   — OpenAI-compatible backend URL (hoặc ANTHROPIC_API_KEY)
#   MINI_BIN            — Override path tới binary (bỏ qua auto-detect)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

# ─── Auto-detect OS + arch ────────────────────────────────────────────────────
_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
_arch="$(uname -m)"

case "$_arch" in
    x86_64|amd64)   _arch="amd64" ;;
    aarch64|arm64)  _arch="arm64" ;;
esac
case "$_os" in
    darwin) _os="darwin" ;;
    linux)  _os="linux" ;;
esac

PREBUILT_NAME="mini-${_os}-${_arch}"
PREBUILT_BIN="$PROJECT_ROOT/bin/$PREBUILT_NAME"

# ─── Binary resolution (priority order) ──────────────────────────────────────
# 1. $MINI_BIN env var              — explicit override
# 2. bin/mini-{os}-{arch}           — platform-specific prebuilt
# 3. bin/mini                       — generic prebuilt
# 4. zig-out/bin/mini               — local dev build
# 5. build from source              — fallback cuối

if [[ -n "${MINI_BIN:-}" ]]; then
    echo "[newspaper] Using binary: $MINI_BIN (from env)"
elif [[ -f "$PREBUILT_BIN" ]]; then
    MINI_BIN="$PREBUILT_BIN"
    echo "[newspaper] Using prebuilt: bin/$PREBUILT_NAME"
elif [[ -f "$PROJECT_ROOT/bin/mini" ]]; then
    MINI_BIN="$PROJECT_ROOT/bin/mini"
    echo "[newspaper] Using prebuilt: bin/mini"
elif [[ -f "$PROJECT_ROOT/zig-out/bin/mini" ]]; then
    MINI_BIN="$PROJECT_ROOT/zig-out/bin/mini"
    echo "[newspaper] Using local build: zig-out/bin/mini"
else
    echo "[newspaper] ⚠ No binary found for ${_os}/${_arch}"
    echo "[newspaper] Building from source (this takes ~1 min first time)..."
    cd "$PROJECT_ROOT"
    ZIG="${HOME}/setup/zig/zig"
    [[ -x "$ZIG" ]] || ZIG="$(command -v zig)"
    "$ZIG" build -Doptimize=ReleaseSafe
    mkdir -p "$PROJECT_ROOT/bin"
    cp "zig-out/bin/mini" "$PROJECT_ROOT/bin/mini"
    MINI_BIN="$PROJECT_ROOT/bin/mini"
    echo "[newspaper] ✓ Built and saved to bin/mini"
fi

# ─── Load .env ────────────────────────────────────────────────────────────────
for ENV_FILE in "$PROJECT_ROOT/.env" "$HOME/.mini/.env"; do
    if [[ -f "$ENV_FILE" ]]; then
        echo "[newspaper] Loading env: $ENV_FILE"
        set -a; source "$ENV_FILE"; set +a
        break
    fi
done

# ─── Parse args ───────────────────────────────────────────────────────────────
HN_TOP=20
NO_AI=false
CRON_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hn-top)      HN_TOP="$2"; shift 2 ;;
        --no-ai)       NO_AI=true; shift ;;
        --cron)        CRON_MODE=true; shift ;;
        *) shift ;;
    esac
done

# ─── Output path ──────────────────────────────────────────────────────────────
DATE=$(date +%Y-%m-%d)

if [[ "$CRON_MODE" == "true" ]]; then
    echo "[newspaper] Cron mode enabled"
fi

# ─── Build agent prompt ───────────────────────────────────────────────────────
NO_AI_NOTE=""
[[ "$NO_AI" == "true" ]] && NO_AI_NOTE="IMPORTANT: Skip all AI analysis. Output raw data only."

read -r -d '' AGENT_PROMPT << PROMPT || true
Generate today's Daily Tech Digest report. Follow these exact steps:

**Configuration:**
- HN stories to fetch: ${HN_TOP}
${NO_AI_NOTE}

**Step 1: Get today's date**
Use bash to run: date +"%A, %B %-d, %Y"
Also run: date "+%Y-%m-%d %H:%M UTC"

**Step 2: Fetch Hacker News**
2a. GET https://hacker-news.firebaseio.com/v0/topstories.json
    — Take the first ${HN_TOP} IDs from the JSON array

2b. For each story ID, GET https://hacker-news.firebaseio.com/v0/item/{id}.json
    — Collect: id, title, url, score, by, descendants, time, kids, type, text

2c. For the top 10 stories only, fetch the first 3 comment IDs from kids[]:
    GET https://hacker-news.firebaseio.com/v0/item/{comment_id}.json
    — Collect: id, by, text (strip HTML tags from text)

**Step 3: Send the complete Markdown report**
Call the MCP tool \`wdvn_api__send_report\` and pass the complete markdown report string as the \`content\` argument, and \`newspaper_YYYY-MM-DD.md\` as the \`filename\` argument (using today's date). This tool securely posts the report. Do not try to use curl or python directly.


The report must follow this exact structure:

# 📰 Tech Digest — {FULL_DATE}

> 🤖 Powered by mini-agent | Generated {TIMESTAMP}
> 🔗 Source: [Hacker News](https://news.ycombinator.com)

---

## 🔥 Hacker News — Top {HN_STORIES} Stories

### 🧠 AI Analysis
{Executive summary, trending topics, community pulse, editor's top 3 picks}

### 📊 Quick Reference

| # | Title | ⬆ Score | 💬 Comments | Domain |
|---|-------|---------|------------|--------|
{One row per story}

### 💬 Stories & Discussions
{For each story:}
#### {N}. [{Title}]({URL})
⬆ **{score}** | 💬 [{comments} comments](https://news.ycombinator.com/item?id={id}) | 👤 {author} | 🌐 {domain} | 🕒 {age}

{If body text: > {truncated body}}

<details>
<summary>💬 Top comments</summary>

**1. {author}:** > {comment text, HTML stripped}

</details>

---

*🤖 Generated by mini-agent Newspaper at {TIMESTAMP}*

**Step 4: Report completion**
Tell the user: "✓ Daily digest sent to https://me.thewdvn.cc/api/mcp/tools"
PROMPT

# ─── Execute ──────────────────────────────────────────────────────────────────
echo "[newspaper] Starting Daily Newspaper Agent..."
echo "[newspaper] Config: HN top=${HN_TOP}"
echo "[newspaper] Endpoint: https://me.thewdvn.cc/api/mcp/tools"
echo ""

export MINI_SYSTEM_FILE="$SKILL_DIR/system_prompt.md"
export MINI_NO_HISTORY=1

"$MINI_BIN" -e "$AGENT_PROMPT"

STATUS=$?
echo ""
if [[ $STATUS -eq 0 ]]; then
    echo "[newspaper] ✓ Agent completed successfully and sent report."
else
    echo "[newspaper] ✗ Agent failed (exit code $STATUS)" >&2
    exit $STATUS
fi
