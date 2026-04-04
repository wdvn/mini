//! config.zig — Tải cấu hình từ biến môi trường và file .env.
//!
//! ## Thứ tự tìm file .env (ưu tiên từ cao xuống thấp)
//!   1. `$MINI_ENV_FILE`      — đường dẫn chỉ định rõ
//!   2. `./.env`              — thư mục làm việc hiện tại (project-level)
//!   3. `~/.mini/.env`        — user-level config
//!
//! Shell environment variables luôn CÓ ƯU TIÊN CAO HƠN giá trị trong file .env
//! (dùng `setenv` với overwrite=0).
//!
//! ## Biến môi trường được hỗ trợ
//!
//! ### Backend AI
//!   `OPENAI_COMPAT_URL`     URL OpenAI-compatible (ưu tiên cao nhất)
//!   `OPENAI_COMPAT_MODEL`   Tên model (mặc định: gpt-4o-mini)
//!   `OPENAI_COMPAT_API_KEY` API key (tuỳ chọn, một số endpoint không cần)
//!   `OPENAI_COMPAT_API_HEADER` Header tên (mặc định: Authorization)
//!   `ANTHROPIC_API_KEY`     Claude API key
//!   `OLLAMA_HOST`           Ollama base URL (mặc định: http://localhost:11434)
//!   `OLLAMA_MODEL`          Ollama model (mặc định: llama3)
//!
//! ### Agent
//!   `MINI_MAX_TOKENS`       Giới hạn token response (mặc định: 8192)
//!   `MINI_SYSTEM_FILE`      Đường dẫn file system prompt (.md)
//!   `MINI_NO_HISTORY`       "1" để tắt lưu lịch sử in-memory
//!
//! ### Tools
//!   `MINI_TOOL_ALLOWLIST`   Chỉ cho phép các tool này (comma-separated)
//!   `MINI_TOOL_BLOCKLIST`   Chặn các tool này (comma-separated)
//!
//! ### MCP
//!   `MINI_MCP_CONFIG`       Đường dẫn file mcp.json (mặc định: ~/.mini/mcp.json)

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

// ---------------------------------------------------------------------------
// libc setenv (POSIX)
// ---------------------------------------------------------------------------

/// setenv(key, value, overwrite) từ libc.
/// overwrite=0: không ghi đè nếu đã tồn tại trong env.
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// ---------------------------------------------------------------------------
// Config struct
// ---------------------------------------------------------------------------

/// Cấu hình đầy đủ của mini-agent, đọc từ biến môi trường.
pub const Config = struct {
    // Backend
    /// URL OpenAI-compatible (ưu tiên cao nhất). Null = không cấu hình.
    openai_compat_url: ?[]const u8,
    /// API key cho OpenAI-compatible endpoint. Null = không cần key.
    openai_compat_key: ?[]const u8,
    /// Header tên chứa API key (mặc định: Authorization).
    openai_compat_api_header: []const u8,
    /// Model cho OpenAI-compatible endpoint.
    openai_compat_model: []const u8,
    /// Anthropic API key. Null = không cấu hình.
    anthropic_key: ?[]const u8,
    /// Claude model ID.
    claude_model: []const u8,
    /// Ollama base URL.
    ollama_url: []const u8,
    /// Ollama model name.
    ollama_model: []const u8,

    // Agent
    /// Số token tối đa trong một response.
    max_tokens: u32,
    /// Nội dung system prompt (đọc từ file hoặc dùng default).
    system_prompt: []const u8,
    /// Bộ nhớ được cấp phát cho system_prompt (null nếu dùng default).
    system_prompt_buf: ?[]u8,

    // Tools
    /// Comma-separated allowlist. Null = cho phép tất cả.
    tool_allowlist: ?[]const u8,
    /// Comma-separated blocklist. Null = không chặn gì.
    tool_blocklist: ?[]const u8,

    // MCP
    /// Đường dẫn file mcp.json. Null = dùng default ~/.mini/mcp.json.
    mcp_config_path: ?[]const u8,

    // History
    /// false = không lưu lịch sử.
    history_enabled: bool,

    /// Default system prompt khi không cấu hình MINI_SYSTEM_FILE.
    pub const default_system_prompt =
        \\Bạn là mini-agent, một AI assistant mạnh mẽ chạy trên terminal.
        \\Bạn có thể dùng các tool như bash, file_read, file_write, http_request,
        \\web_search, glob, grep để hoàn thành nhiệm vụ.
        \\Hãy trả lời ngắn gọn, chính xác và hữu ích bằng tiếng Việt.
    ;

    /// Đọc cấu hình từ biến môi trường (sau khi đã gọi loadDotEnv).
    /// `alloc` dùng để đọc file system prompt nếu cần.
    pub fn load(alloc: Allocator) !Config {
        const openai_url = std.posix.getenv("OPENAI_COMPAT_URL");
        const openai_key = std.posix.getenv("OPENAI_COMPAT_API_KEY");
        const openai_api_header = std.posix.getenv("OPENAI_COMPAT_API_HEADER") orelse "Authorization";
        const openai_model = std.posix.getenv("OPENAI_COMPAT_MODEL") orelse "gpt-4o-mini";
        const anthropic_key = std.posix.getenv("ANTHROPIC_API_KEY");
        const claude_model = std.posix.getenv("CLAUDE_MODEL") orelse "claude-opus-4-5";
        const ollama_url = std.posix.getenv("OLLAMA_HOST") orelse "http://localhost:11434";
        const ollama_model = std.posix.getenv("OLLAMA_MODEL") orelse "llama3";

        // Kiểm tra có ít nhất một backend
        if (openai_url == null and anthropic_key == null) {
            try std.fs.File.stderr().writeAll(
                \\[config] Lỗi: chưa cấu hình AI backend.
                \\
                \\Thiết lập một trong các biến sau:
                \\  OPENAI_COMPAT_URL=http://localhost:11434/v1
                \\  ANTHROPIC_API_KEY=sk-ant-...
                \\
                \\Hoặc tạo file .env trong thư mục hiện tại.
                \\
            );
            return error.MissingBackend;
        }

        const max_tokens: u32 = blk: {
            const s = std.posix.getenv("MINI_MAX_TOKENS") orelse break :blk 8192;
            break :blk std.fmt.parseInt(u32, s, 10) catch 8192;
        };

        const history_enabled = blk: {
            const v = std.posix.getenv("MINI_NO_HISTORY") orelse break :blk true;
            break :blk !std.mem.eql(u8, v, "1");
        };

        // System prompt: từ file hoặc default
        const sp_result = loadSystemPrompt(alloc);

        return .{
            .openai_compat_url = openai_url,
            .openai_compat_key = openai_key,
            .openai_compat_api_header = openai_api_header,
            .openai_compat_model = openai_model,
            .anthropic_key = anthropic_key,
            .claude_model = claude_model,
            .ollama_url = ollama_url,
            .ollama_model = ollama_model,
            .max_tokens = max_tokens,
            .system_prompt = sp_result.text,
            .system_prompt_buf = sp_result.buf,
            .tool_allowlist = std.posix.getenv("MINI_TOOL_ALLOWLIST"),
            .tool_blocklist = std.posix.getenv("MINI_TOOL_BLOCKLIST"),
            .mcp_config_path = std.posix.getenv("MINI_MCP_CONFIG"),
            .history_enabled = history_enabled,
        };
    }

    /// Giải phóng bộ nhớ được cấp phát (chỉ system_prompt_buf).
    pub fn deinit(self: *Config, alloc: Allocator) void {
        if (self.system_prompt_buf) |buf| {
            alloc.free(buf);
            self.system_prompt_buf = null;
            self.system_prompt = default_system_prompt;
        }
    }
};

// ---------------------------------------------------------------------------
// System prompt loading
// ---------------------------------------------------------------------------

const SpResult = struct { buf: ?[]u8, text: []const u8 };

fn loadSystemPrompt(alloc: Allocator) SpResult {
    const path = std.posix.getenv("MINI_SYSTEM_FILE") orelse
        return .{ .buf = null, .text = Config.default_system_prompt };

    const file = std.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("[config] Không mở được system prompt: {s}, dùng default.\n", .{path});
        return .{ .buf = null, .text = Config.default_system_prompt };
    };
    defer file.close();

    const stat = file.stat() catch return .{ .buf = null, .text = Config.default_system_prompt };
    if (stat.size == 0 or stat.size > 64 * 1024)
        return .{ .buf = null, .text = Config.default_system_prompt };

    const buf = alloc.alloc(u8, @intCast(stat.size)) catch
        return .{ .buf = null, .text = Config.default_system_prompt };

    const n = utils.readAll(file, buf) catch {
        alloc.free(buf);
        return .{ .buf = null, .text = Config.default_system_prompt };
    };

    std.debug.print("[config] System prompt: {s} ({d} bytes)\n", .{ path, n });
    return .{ .buf = buf, .text = buf[0..n] };
}

// ---------------------------------------------------------------------------
// .env loader
// ---------------------------------------------------------------------------

/// Tải biến môi trường từ các file .env theo thứ tự ưu tiên:
///   1. $MINI_ENV_FILE — đường dẫn tường minh
///   2. ./.env         — thư mục hiện tại
///   3. ~/.mini/.env   — user-level
///
/// Shell env variables luôn có ưu tiên cao hơn (setenv overwrite=0).
/// Hỗ trợ cú pháp: `KEY=VALUE`, `KEY="VALUE"`, `KEY='VALUE'`,
///                 `export KEY=VALUE`, `# comment`, dòng trống.
pub fn loadDotEnv() void {
    const home = std.posix.getenv("HOME");

    // Danh sách ứng viên
    var paths: [3][512]u8 = undefined;
    var path_lens: [3]usize = .{ 0, 0, 0 };
    var n: usize = 0;

    // 1. Explicit override
    if (std.posix.getenv("MINI_ENV_FILE")) |explicit| {
        if (explicit.len > 0 and explicit.len < 512) {
            @memcpy(paths[n][0..explicit.len], explicit);
            path_lens[n] = explicit.len;
            n += 1;
        }
    }

    // 2. CWD/.env
    {
        const name = ".env";
        @memcpy(paths[n][0..name.len], name);
        path_lens[n] = name.len;
        n += 1;
    }

    // 3. ~/.mini/.env
    if (home) |h| {
        const p = std.fmt.bufPrint(&paths[n], "{s}/.mini/.env", .{h}) catch "";
        path_lens[n] = p.len;
        if (p.len > 0) n += 1;
    }

    for (0..n) |i| {
        tryLoadFile(paths[i][0..path_lens[i]]);
    }
}

fn tryLoadFile(path: []const u8) void {
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const r = file.read(buf[total..]) catch break;
        if (r == 0) break;
        total += r;
    }

    var loaded: usize = 0;
    var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Strip "export " prefix
        const eff = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trim(u8, line["export ".len..], " \t")
        else
            line;

        const eq = std.mem.indexOfScalar(u8, eff, '=') orelse continue;
        const key = std.mem.trim(u8, eff[0..eq], " \t");
        var val = std.mem.trim(u8, eff[eq + 1 ..], " \t");

        // Strip surrounding quotes
        if (val.len >= 2) {
            if ((val[0] == '"' and val[val.len - 1] == '"') or
                (val[0] == '\'' and val[val.len - 1] == '\''))
                val = val[1 .. val.len - 1];
        }

        if (key.len == 0 or key.len > 255 or val.len > 4095) continue;

        var key_z: [256]u8 = undefined;
        var val_z: [4096]u8 = undefined;
        @memcpy(key_z[0..key.len], key);
        key_z[key.len] = 0;
        @memcpy(val_z[0..val.len], val);
        val_z[val.len] = 0;

        // Không ghi đè nếu đã có trong shell env
        if (std.posix.getenv(key_z[0..key.len :0]) != null) continue;
        _ = setenv(key_z[0..key.len :0].ptr, val_z[0..val.len :0].ptr, 0);
        loaded += 1;
    }

    if (loaded > 0) {
        std.debug.print("[config] Loaded {d} vars from {s}\n", .{ loaded, path });
    }
}
