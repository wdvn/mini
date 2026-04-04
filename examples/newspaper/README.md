# 📰 Newspaper Agent

> **Wintermolt agent** tổng hợp tin tức hàng ngày từ **Hacker News** + **arXiv** (AI/ML/Algorithms).

Agent này chạy hoàn toàn trên **Wintermolt** (Zig binary) — dùng các built-in tools `http_request`, `file_write`, và `bash` để fetch dữ liệu, phân tích bằng AI, và viết báo cáo Markdown.

---

## Cách chạy

```bash
cd examples/newspaper/

# Mặc định: 20 HN stories + 10 arXiv papers
./run.sh

# Tuỳ chỉnh
./run.sh --hn-top 30            # 30 HN stories
./run.sh --arxiv-count 15        # 15 arXiv papers
./run.sh --sections hn           # Chỉ Hacker News
./run.sh --sections arxiv        # Chỉ arXiv
./run.sh --no-ai                 # Raw data (không cần API key)
./run.sh --output /path/to/report.md

# Cron mode (lưu vào ~/newspaper-digests/)
./run.sh --cron
```

### Build và chạy lần đầu

```bash
# Build wintermolt (nếu chưa có binary)
cd /home/mypc/projects/mini
zig build

# Set API key
export ANTHROPIC_API_KEY=sk-ant-...

# Chạy newspaper agent
cd examples/newspaper
./run.sh
```

---

## Cron (chạy tự động hàng ngày)

```bash
crontab -e
```
```
# Mỗi ngày 7:00 sáng
0 7 * * * cd /home/mypc/projects/mini && ANTHROPIC_API_KEY=sk-ant-... examples/newspaper/run.sh --cron >> ~/newspaper-digests/cron.log 2>&1
```

Output lưu vào: `~/newspaper-digests/newspaper_YYYY-MM-DD.md`

---

## Files

| File | Mô tả |
|------|-------|
| `run.sh` | Runner chính — gọi Wintermolt binary |
| `skill.json` | Skill manifest (đăng ký với Wintermolt skill system) |
| `system_prompt.md` | Agent constitution — hướng dẫn chi tiết cho agent |

---

## Kiến trúc

```
run.sh
  └─ WINTERMOLT_CONSTITUTION=system_prompt.md
  └─ wintermolt -e "Generate daily digest..."
       │
       ├─ [http_request] GET HN Firebase API → top story IDs
       ├─ [http_request] × N → story + comment details
       ├─ [http_request] GET arXiv Atom feed → XML
       ├─ [bash] parse XML, format data
       └─ [file_write] → newspaper_YYYY-MM-DD.md
```

**Wintermolt tools được dùng:**
- `http_request` — Fetch HN API + arXiv Atom feed
- `bash` — Lấy ngày, parse XML
- `file_write` — Lưu digest Markdown

---

## Output

File `newspaper_YYYY-MM-DD.md` gồm:

| Section | Nội dung |
|---------|----------|
| 🧩 Cross-Domain Insights | Liên kết giữa industry news và academic research |
| 🔥 Hacker News | AI Analysis + Quick Reference table + Stories & Discussions |
| 🔬 arXiv Research | Research Summary + Papers Table + Paper Details |

---

## AI Backend

Dùng config của Wintermolt (đã set qua `wintermolt --setup` hoặc `.env`):

| Backend | Env var |
|---------|---------|
| Claude (mặc định) | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` + `WINTERMOLT_MODEL=openai` |
| Ollama | `WINTERMOLT_OLLAMA_URL` |

---

## Cài đặt như Wintermolt Skill (tuỳ chọn)

```bash
# Link skill vào skills/ directory để dùng /newspaper trong REPL
mkdir -p ~/.wintermolt/skills
ln -s /home/mypc/projects/mini/examples/newspaper ~/.wintermolt/skills/newspaper

# Sau đó trong wintermolt REPL:
wintermolt
> /newspaper
```
