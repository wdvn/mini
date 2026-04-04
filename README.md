# mini-agent

> **mini-agent** là một AI agent chạy trên terminal, được xây dựng bằng **Zig 0.15.2**.  
> Nhỏ gọn, không phụ thuộc, hỗ trợ đa backend, có tool system đầy đủ và tích hợp MCP.

```
mini-agent 1.0.0 | openai-compat (gpt-4o-mini)
Gõ /help để xem lệnh, /quit để thoát.

You > viết cho tôi một đoạn code fibonacci bằng Python
[tool: bash] [ok]
Đây là hàm fibonacci sử dụng memoization...
```

---

## Mục lục

- [Tính năng](#tính-năng)
- [Yêu cầu hệ thống](#yêu-cầu-hệ-thống)
- [Cài đặt & Build](#cài-đặt--build)
- [Cấu hình](#cấu-hình)
  - [Backends AI](#backends-ai)
  - [Agent](#agent)
  - [Tools](#tools)
  - [MCP](#mcp)
  - [File .env](#file-env)
- [Cách dùng](#cách-dùng)
  - [REPL tương tác](#repl-tương-tác)
  - [Single-shot](#single-shot)
  - [Lệnh REPL (slash commands)](#lệnh-repl-slash-commands)
- [Tool system](#tool-system)
  - [bash](#bash)
  - [file\_read](#file_read)
  - [file\_write](#file_write)
  - [file\_edit](#file_edit)
  - [glob](#glob)
  - [grep](#grep)
  - [http\_request](#http_request)
  - [web\_search](#web_search)
  - [skills](#skills)
- [MCP (Model Context Protocol)](#mcp-model-context-protocol)
- [Kiến trúc mã nguồn](#kiến-trúc-mã-nguồn)
- [Ví dụ: Newspaper Agent](#ví-dụ-newspaper-agent)
- [Đóng góp](#đóng-góp)

---

## Tính năng

| Tính năng | Chi tiết |
|---|---|
| **Đa backend** | OpenAI-compatible, Anthropic Claude, Ollama (local) |
| **Streaming** | Hiển thị text real-time khi AI đang sinh |
| **Agentic loop** | Tự động gọi tools rồi gửi kết quả lại AI (tối đa 20 vòng) |
| **Tool system** | 9 built-in tools: bash, file, glob, grep, http, search, skills |
| **MCP** | Kết nối MCP servers bên ngoài qua JSON-RPC over stdio |
| **Policy tools** | Allowlist / blocklist để kiểm soát tool nào được phép chạy |
| **Lịch sử** | In-memory conversation history với auto-compacting |
| **System prompt** | Tùy chỉnh từ file `.md` bất kỳ |
| **Auto .env** | Tự động tải `.env` từ CWD, `~/.mini/.env` |
| **Nhỏ gọn** | 1 binary (~12MB Release), chỉ phụ thuộc `libcurl` |

---

## Yêu cầu hệ thống

| Thành phần | Phiên bản tối thiểu |
|---|---|
| **Zig** | 0.15.2 |
| **libcurl** | ≥ 7.x (dev headers) |
| **OS** | Linux x86\_64 (đã test), macOS (chưa test) |

Cài đặt Zig 0.15.2:

```bash
# Tải từ trang chính thức
curl -LO https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
tar -xf zig-linux-x86_64-0.15.2.tar.xz
export PATH="$PWD/zig-linux-x86_64-0.15.2:$PATH"
```

Cài libcurl:

```bash
# Ubuntu / Debian
sudo apt install libcurl4-openssl-dev

# Arch Linux
sudo pacman -S curl

# Fedora / RHEL
sudo dnf install libcurl-devel
```

---

## Cài đặt & Build

```bash
# Clone project
git clone <repo-url>
cd mini

# Build (dùng Zig 0.15.2)
zig build

# Binary ở: zig-out/bin/mini-agent
./zig-out/bin/mini-agent --version
# mini-agent 1.0.0
```

Build tối ưu hóa cho production:

```bash
zig build -Doptimize=ReleaseSafe
# hoặc
zig build -Doptimize=ReleaseSmall   # nhỏ nhất
zig build -Doptimize=ReleaseFast    # nhanh nhất
```

Cross-compile:

```bash
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-linux-gnu   # ARM64
```

Cài vào PATH hệ thống:

```bash
sudo cp zig-out/bin/mini-agent /usr/local/bin/
mini-agent --version
```

---

## Cấu hình

mini-agent đọc cấu hình từ biến môi trường. Tự động load file `.env` trước khi đọc env.

### Backends AI

Agent chọn backend theo **thứ tự ưu tiên**:

1. **OpenAI-compatible** (nếu có `OPENAI_COMPAT_URL`)
2. **Anthropic Claude** (nếu có `ANTHROPIC_API_KEY`)
3. **Ollama** (fallback local — luôn thử nếu backends kia thất bại)

| Biến môi trường | Mô tả | Mặc định |
|---|---|---|
| `OPENAI_COMPAT_URL` | URL base của API OpenAI-compatible | — |
| `OPENAI_COMPAT_MODEL` | Tên model | `gpt-4o-mini` |
| `OPENAI_COMPAT_API_KEY` | API key (bỏ qua nếu không cần) | — |
| `OPENAI_COMPAT_API_HEADER` | Tên HTTP header chứa API key | `Authorization` |
| `ANTHROPIC_API_KEY` | Claude API key | — |
| `CLAUDE_MODEL` | Claude model ID | `claude-opus-4-5` |
| `OLLAMA_HOST` | URL Ollama server | `http://localhost:11434` |
| `OLLAMA_MODEL` | Tên model Ollama | `llama3` |

**Ví dụ cụ thể:**

```bash
# OpenAI
export OPENAI_COMPAT_URL=https://api.openai.com/v1
export OPENAI_COMPAT_API_KEY=sk-...
export OPENAI_COMPAT_MODEL=gpt-4o

# OpenRouter (hỗ trợ nhiều model)
export OPENAI_COMPAT_URL=https://openrouter.ai/api/v1
export OPENAI_COMPAT_API_KEY=sk-or-...
export OPENAI_COMPAT_MODEL=anthropic/claude-3-5-sonnet

# Claude trực tiếp
export ANTHROPIC_API_KEY=sk-ant-...

# LM Studio (local)
export OPENAI_COMPAT_URL=http://localhost:1234/v1

# Ollama (local, không cần API key)
export OLLAMA_HOST=http://localhost:11434
export OLLAMA_MODEL=llama3.2
```

### Agent

| Biến môi trường | Mô tả | Mặc định |
|---|---|---|
| `MINI_MAX_TOKENS` | Số token tối đa mỗi response | `8192` |
| `MINI_SYSTEM_FILE` | Đường dẫn file system prompt (`.md`) | — |
| `MINI_NO_HISTORY` | `"1"` để tắt lưu lịch sử hội thoại | — |

**System prompt tùy chỉnh:**

```bash
# Tạo file system prompt
cat > my_prompt.md << 'EOF'
Bạn là một senior Zig developer. Khi được hỏi về code,
hãy viết code rõ ràng, có comment, và giải thích từng bước.
Luôn check error handling.
EOF

export MINI_SYSTEM_FILE=my_prompt.md
mini-agent
```

### Tools

| Biến môi trường | Mô tả | Ví dụ |
|---|---|---|
| `MINI_TOOL_ALLOWLIST` | Chỉ cho phép các tool này (comma-separated) | `bash,file_read,grep` |
| `MINI_TOOL_BLOCKLIST` | Chặn các tool này (comma-separated) | `bash,http_request` |

> **Lưu ý:** Allowlist có ưu tiên cao hơn blocklist. Nếu set allowlist, chỉ những tool trong list mới chạy được.

```bash
# Chỉ cho phép đọc file và tìm kiếm (safe mode)
MINI_TOOL_ALLOWLIST=file_read,glob,grep mini-agent

# Tắt bash (môi trường hạn chế)
MINI_TOOL_BLOCKLIST=bash mini-agent
```

### MCP

| Biến môi trường | Mô tả | Mặc định |
|---|---|---|
| `MINI_MCP_CONFIG` | Đường dẫn file `mcp.json` | `~/.mini/mcp.json` |

Xem chi tiết trong phần [MCP](#mcp-model-context-protocol).

### File .env

mini-agent tự động tìm file `.env` theo thứ tự ưu tiên:

1. `$MINI_ENV_FILE` — đường dẫn tường minh
2. `./.env` — thư mục làm việc hiện tại *(ưu tiên)*
3. `~/.mini/.env` — user-level config

> **Quy tắc:** Biến đã có trong shell environment **không bị ghi đè** bởi file `.env`.

**Cú pháp `.env` được hỗ trợ:**

```bash
# Khai báo biến bình thường
OPENAI_COMPAT_URL=https://api.openai.com/v1

# Có thể dùng dấu ngoặc đơn hoặc kép
OPENAI_COMPAT_API_KEY="sk-abc123"
CLAUDE_MODEL='claude-opus-4-5'

# Có thể dùng export (như bash)
export OLLAMA_MODEL=llama3

# Comment bắt đầu bằng #
# ANTHROPIC_API_KEY=sk-ant-xxx   ← dòng này bị bỏ qua
```

**Ví dụ `.env` cho development project:**

```bash
# .env
OPENAI_COMPAT_URL=http://localhost:11434/v1
OPENAI_COMPAT_MODEL=llama3.2
MINI_SYSTEM_FILE=./prompts/developer.md
MINI_TOOL_BLOCKLIST=bash
MINI_MAX_TOKENS=4096
```

---

## Cách dùng

### REPL tương tác

```bash
# Khởi động REPL
mini-agent

# REPL với system prompt tùy chỉnh
mini-agent --system ./my_system.md

# REPL với backend cụ thể
mini-agent --model claude

# REPL không kết nối MCP
mini-agent --no-mcp
```

Giao diện REPL:

```
mini-agent 1.0.0 | claude (claude-opus-4-5)
Gõ /help để xem lệnh, /quit để thoát.

You > liệt kê tất cả file .zig trong project này
[tool: glob] [ok]
Các file .zig trong project:
- src/main.zig
- src/agent.zig
- ...

You > đọc nội dung src/main.zig và giải thích
[tool: file_read] [ok]
File src/main.zig là entry point của mini-agent...
```

### Single-shot

Chạy một prompt và thoát ngay (không có REPL):

```bash
# Dùng flag -e / --exec
mini-agent -e "Tóm tắt README.md của project này"

# Hoặc truyền prompt trực tiếp (positional argument)
mini-agent "Ngày hôm nay là mấy?"

# Kết hợp pipeline
echo "Phân tích lỗi sau: $(cat error.log)" | mini-agent -e "$(cat)"

# Dùng trong script
RESULT=$(mini-agent -e "Viết một unit test cho hàm fibonacci")
echo "$RESULT" > test_fibonacci.py
```

### Lệnh REPL (slash commands)

Trong chế độ REPL, gõ các lệnh bắt đầu bằng `/`:

| Lệnh | Mô tả |
|---|---|
| `/help` | Xem danh sách lệnh và tools |
| `/clear` | Xóa lịch sử hội thoại, clear màn hình |
| `/model <backend>` | Đổi backend đang dùng |
| `/model <backend> <model>` | Đổi backend với model cụ thể |
| `/quit`, `/exit`, `/q` | Thoát |

**Ví dụ đổi backend:**

```
You > /model claude
[agent] Switched to claude (claude-opus-4-5)

You > /model openai gpt-4o
[agent] Switched to openai-compat (gpt-4o)

You > /model ollama llama3.2
[agent] Switched to ollama (llama3.2)
```

---

## Tool system

mini-agent có **9 built-in tools** luôn sẵn sàng. AI tự quyết định khi nào gọi tool nào.

### bash

Chạy lệnh shell, trả về stdout + stderr.

```json
{ "command": "git log --oneline -5" }
```

**Giới hạn an toàn** — các pattern sau bị chặn:
`rm -rf /`, `:(){ :|:& };:`, `mkfs`, `dd if=`, `> /dev/sda`, v.v.

```bash
# Tắt hoàn toàn tool bash
MINI_TOOL_BLOCKLIST=bash mini-agent
```

### file\_read

Đọc nội dung file, trả về dạng có đánh số dòng. Hỗ trợ đọc từng phần cho file lớn.

```json
{ "path": "src/main.zig" }
{ "path": "src/main.zig", "offset": 100, "limit": 50 }
```

**Giới hạn:** 2000 dòng mỗi lần, file tối đa 10MB.

### file\_write

Tạo mới hoặc ghi đè file. Tự động tạo thư mục cha.

```json
{ "path": "output/report.md", "content": "# Báo cáo\n..." }
```

**Giới hạn:** Không ghi vào `/etc`, `/sys`, `/proc`, `/dev`.

### file\_edit

Sửa file bằng cách tìm chuỗi cũ và thay bằng chuỗi mới. Chuỗi tìm kiếm **phải duy nhất** trong file để đảm bảo an toàn.

```json
{
  "path": "src/main.zig",
  "old_string": "const VERSION = \"1.0.0\";",
  "new_string": "const VERSION = \"1.1.0\";"
}
```

### glob

Tìm file theo wildcard pattern. Hỗ trợ `*`, `**`, `?`.

```json
{ "pattern": "**/*.zig" }
{ "pattern": "src/**/*.ts", "path": "./frontend" }
{ "pattern": "*.log", "path": "/var/log" }
```

### grep

Tìm kiếm nội dung trong file hoặc thư mục đệ quy. Trả về `path:dòng:nội_dòng`.

```json
{ "pattern": "fn main", "path": "./src" }
{ "pattern": "TODO", "path": ".", "case_insensitive": "true" }
```

**Giới hạn:** 200 kết quả, bỏ qua file binary và file > 1MB.

### http\_request

Gửi HTTP request đến bất kỳ URL. Hỗ trợ GET, POST, PUT, DELETE, HEAD.

```json
{
  "url": "https://api.github.com/repos/ziglang/zig/releases/latest",
  "method": "GET",
  "headers": { "Accept": "application/json" }
}
```

```json
{
  "url": "https://api.example.com/data",
  "method": "POST",
  "body": "{\"key\": \"value\"}",
  "headers": {
    "Content-Type": "application/json",
    "Authorization": "Bearer token123"
  }
}
```

**Giới hạn:** Response tối đa 30KB, timeout 30 giây.

### web\_search

Tìm kiếm web qua DuckDuckGo Lite. **Không cần API key.**

```json
{ "query": "Zig 0.15 release notes" }
{ "query": "cách cài docker trên ubuntu", "num_results": 10 }
```

Trả về tiêu đề + URL + snippet cho mỗi kết quả (tối đa 10).

### skills

Xem danh sách và chi tiết các tool.

```json
{ "operation": "list" }
{ "operation": "detail", "name": "bash" }
```

---

## MCP (Model Context Protocol)

mini-agent hỗ trợ kết nối với **MCP servers** bên ngoài theo chuẩn [MCP](https://modelcontextprotocol.io). Mỗi server được spawn như một child process, giao tiếp qua stdin/stdout (JSON-RPC 2.0).

### Cấu hình

Tạo file `~/.mini/mcp.json` (hoặc chỉ định qua `MINI_MCP_CONFIG`):

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
    },
    "database": {
      "command": "python3",
      "args": ["-m", "mcp_server_sqlite", "mydb.sqlite"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
    }
  }
}
```

### Tool naming

Tên tool MCP có prefix server, ngăn cách bởi `__`:

```
filesystem__read_file
filesystem__write_file
database__query
database__execute
github__search_repositories
```

### Ví dụ dùng MCP filesystem server

```bash
# Cài MCP server (một lần)
npm install -g @modelcontextprotocol/server-filesystem

# Cấu hình
mkdir -p ~/.mini
cat > ~/.mini/mcp.json << 'EOF'
{
  "servers": {
    "fs": {
      "command": "mcp-server-filesystem",
      "args": ["/home/mypc/projects"]
    }
  }
}
EOF

# Chạy mini-agent (tự động kết nối MCP)
mini-agent
```

Trong REPL, AI có thể tự động dùng `fs__read_file`, `fs__list_directory`, v.v.

### Tắt MCP

```bash
mini-agent --no-mcp
```

---

## Kiến trúc mã nguồn

```
mini/
├── build.zig           # Build system (Zig 0.15.2)
├── build.zig.zon       # Package manifest
├── docs/
│   └── plan.md         # Tài liệu kế hoạch kiến trúc
├── examples/
│   └── newspaper/      # Ví dụ: News digest agent
│       ├── run.sh
│       ├── system_prompt.md
│       └── skill.json
└── src/
    ├── main.zig        # Entry point: CLI parsing, MCP init, REPL/single-shot
    ├── agent.zig       # AgentLoop: vòng lặp chính, tool execution
    ├── config.zig      # .env loader, Config struct
    ├── history.zig     # In-memory conversation buffer (auto-compact)
    ├── protocol.zig    # Shared types: Message, ContentBlock, Response, ToolDefinition
    ├── json.zig        # JSON parser/builder không cần thư viện ngoài
    ├── sse.zig         # HTTP/SSE transport qua libcurl
    ├── mcp.zig         # MCP client manager (JSON-RPC over stdio)
    ├── tools.zig       # Tool registry, dispatcher, policy enforcement
    ├── backend/
    │   ├── openai.zig  # OpenAI-compatible streaming client (SSE)
    │   ├── claude.zig  # Anthropic Claude streaming client (SSE)
    │   └── ollama.zig  # Ollama local AI client (NDJSON)
    └── tools/
        ├── bash.zig    # Shell execution với safety blocklist
        ├── file.zig    # file_read, file_write, file_edit
        ├── glob.zig    # Wildcard file finder
        ├── grep.zig    # Recursive content search
        ├── http.zig    # HTTP client (libcurl)
        └── search.zig  # DuckDuckGo web search
```

### Luồng xử lý một tin nhắn

```
User input
    │
    ▼
history.addUser(text)
    │
    ▼
tools.getRelevantDefinitions(text)   ← lọc tool phù hợp
    │
    ┌─────────────────────────────────┐
    │         Agentic Loop            │
    │  (tối đa 20 iterations)         │
    │                                 │
    │  backend.sendMessage()          │  ← streaming SSE/NDJSON
    │      │                          │
    │      ▼                          │
    │  response.stop_reason?          │
    │      ├── end_turn ──────────────┼──► trả về
    │      └── tool_use ─────────────┤
    │              │                  │
    │              ▼                  │
    │      tools.executeTool() × N    │
    │              │                  │
    │              ▼                  │
    │      history.addToolResults()   │
    │              │                  │
    │              └── tiếp tục ──────┘
    └─────────────────────────────────┘
```

### Module dependencies

```
main.zig
  ├── config.zig          (loadDotEnv, Config.load)
  ├── mcp.zig             (McpClientManager)
  ├── tools.zig           (setMcpManager, setPolicy)
  └── agent.zig
        ├── protocol.zig  (Message, Response, ToolDefinition)
        ├── history.zig   (History buffer)
        ├── tools.zig     (executeTool, getRelevantDefinitions)
        └── backend/
              ├── openai.zig  ──► sse.zig ──► libcurl
              ├── claude.zig  ──► sse.zig ──► libcurl
              └── ollama.zig  ──► sse.zig ──► libcurl
```

### API đặc thù Zig 0.15.2

> Zig 0.15 đã thay đổi một số API quan trọng. Đây là các pattern được dùng trong codebase:

| API cũ (0.14) | API trong 0.15.2 |
|---|---|
| `std.ArrayList(T).init(a)` | `std.ArrayListUnmanaged(T){}` |
| `.append(item)` | `.append(alloc, item)` |
| `.deinit()` | `.deinit(alloc)` |
| `buf.writer()` | `buf.writer(alloc)` |
| `buf.toOwnedSlice()` | `buf.toOwnedSlice(alloc)` |
| `std.io.getStdOut().writer()` | `std.fs.File.stdout().deprecatedWriter()` |
| `callconv(.C)` | `callconv(.{ .x86_64_sysv = .{} })` |

---

## Ví dụ: Newspaper Agent

`examples/newspaper/` là một agent hoàn chỉnh tổng hợp tin tức từ Hacker News và arXiv mỗi ngày.

```bash
cd examples/newspaper

# Cần có API key
export ANTHROPIC_API_KEY=sk-ant-...
# hoặc
export OPENAI_COMPAT_URL=https://api.openai.com/v1
export OPENAI_COMPAT_API_KEY=sk-...

# Chạy (tạo file báo cáo Markdown)
./run.sh

# Tuỳ chỉnh
./run.sh --hn-top 30           # 30 HN stories
./run.sh --arxiv-count 15      # 15 arXiv papers
./run.sh --sections hn         # Chỉ Hacker News
./run.sh --no-ai               # Không dùng AI (raw data)
./run.sh --cron                # Lưu vào ~/newspaper-digests/

# Tự động hàng ngày (crontab)
crontab -e
# 0 7 * * * cd /path/to/mini && ./examples/newspaper/run.sh --cron
```

Output: file `newspaper_YYYY-MM-DD.md` với các section:
- 🧩 Cross-Domain Insights
- 🔥 Hacker News — AI analysis + Quick Reference + Stories
- 🔬 arXiv Research — Research Summary + Papers

Xem thêm: [examples/newspaper/README.md](examples/newspaper/README.md)

---

## Đóng góp

### Thêm tool mới

1. Tạo file `src/tools/mytool.zig` với pattern:

```zig
//! tools/mytool.zig — Mô tả ngắn gọn.
//!
//! ## Input schema
//! ```json
//! { "param1": "value" }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");

pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const param = json.findString(input_json, "param1") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu param1", .{});
    // ... logic
    return std.fmt.allocPrint(alloc, "Kết quả: {s}", .{param});
}
```

2. Import và đăng ký trong `src/tools.zig`:

```zig
const mytool = @import("tools/mytool.zig");

// Trong executeTool():
if (std.mem.eql(u8, name, "mytool")) return mytool.executeTool(alloc, input_json);

// Trong definitions[]:
.{
    .name = "mytool",
    .description = "Mô tả cho AI hiểu khi nào dùng tool này.",
    .input_schema_json = \\{"type":"object","properties":{"param1":{"type":"string"}},"required":["param1"]}
    ,
},

// Trong core_tools[]:
"mytool",
```

### Thêm backend mới

Implement interface:

```zig
pub const Client = struct {
    alloc: Allocator,
    // ... fields

    pub fn init(...) Client { ... }

    pub fn sendMessage(
        self: *Client,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tools: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
    ) !proto.Response { ... }
};
```

Đăng ký trong `src/agent.zig` — `Backend` union và `AgentLoop.init()`.

---

## License

MIT — xem file [LICENSE](LICENSE).

---

*Built with ❤️ using Zig 0.15.2*
