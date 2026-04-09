//! main.zig — Entry point của mini-agent.
//!
//! ## Luồng khởi động
//! ```
//! parse CLI args
//!   → config.loadDotEnv()       load .env files
//!   → Config.load()             đọc env vars → Config struct
//!   → McpClientManager.init()   kết nối MCP servers (nếu không có --no-mcp)
//!   → tools.setMcpManager()     đăng ký MCP vào tool dispatcher
//!   → AgentLoop.init()          chọn backend, khởi tạo history
//!   → [single-shot] -e "..."    gửi prompt, in kết quả, thoát
//!   → [REPL]                    vòng lặp đọc stdin
//! ```
//!
//! ## CLI flags
//! ```
//! mini-agent [options]
//!   -e <prompt>        Chạy single-shot và thoát
//!   --system <file>    Dùng file này làm system prompt
//!   --no-mcp           Không kết nối MCP servers
//!   --model <backend>  Chọn backend: openai, claude, ollama
//!   --version          In phiên bản
//!   --help, -h         In hướng dẫn
//! ```
//!
//! ## Slash commands trong REPL
//! ```
//! /quit, /exit, /q   Thoát
//! /clear             Xóa lịch sử hội thoại
//! /help              Xem danh sách tools và lệnh
//! /model <backend>   Đổi backend
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const mcp_mod = @import("mcp.zig");
const utils = @import("utils.zig");

const VERSION = "1.0.0";
const PROMPT_PREFIX = "\x1b[1;34mYou\x1b[0m > ";

// ---------------------------------------------------------------------------
// I/O helpers — Zig 0.15.2: File.writeAll() + bufPrint, std.debug.print
// ---------------------------------------------------------------------------

/// In formatted string ra stdout dùng stack buffer.
fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

/// In formatted string ra stderr (thread-safe via std.debug.print).
fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Đọc một dòng từ stdin, bỏ '\r'. Trả về null nếu EOF.
fn readLine(stdin: std.fs.File, buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = stdin.read(&byte) catch return null;
        if (n == 0) {
            if (i == 0) return null;
            return buf[0..i];
        }
        if (byte[0] == '\n') return buf[0..i];
        if (byte[0] != '\r') {
            buf[i] = byte[0];
            i += 1;
        }
    }
    return buf[0..i];
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse CLI args
    const args_raw = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args_raw);
    const args = try parseArgs(args_raw[1..]);

    if (args.show_help) {
        printHelp();
        return;
    }
    if (args.show_version) {
        stdoutPrint("mini-agent {s}\n", .{VERSION});
        return;
    }

    // Thiết lập env file từ --system trước khi loadDotEnv nếu cần
    // (MINI_SYSTEM_FILE có thể được set trong .env)
    config_mod.loadDotEnv();

    // Load config
    var cfg = config_mod.Config.load(alloc) catch |e| {
        stderrPrint("Lỗi load config: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer cfg.deinit(alloc);

    // Override system prompt từ CLI
    if (args.system_file) |sfile| {
        const file = std.fs.cwd().openFile(sfile, .{}) catch |e| {
            stderrPrint("Không mở được system file '{s}': {s}\n", .{ sfile, @errorName(e) });
            std.process.exit(1);
        };
        defer file.close();
        const stat = try file.stat();
        const buf = try alloc.alloc(u8, @intCast(stat.size));
        const n = try utils.readAll(file, buf);
        if (cfg.system_prompt_buf) |old| alloc.free(old);
        cfg.system_prompt_buf = buf;
        cfg.system_prompt = buf[0..n];
    }

    // MCP setup
    var mcp = mcp_mod.McpClientManager.init(alloc);
    defer mcp.deinit();
    if (!args.no_mcp) {
        mcp.loadFromConfig(cfg.mcp_config_path);
        tools_mod.setMcpManager(&mcp);
        if (mcp.toolCount() > 0) {
            stderrPrint("[main] MCP: {d} tools từ {d} server(s)\n", .{ mcp.toolCount(), mcp.servers.items.len });
        }
    }

    // Khởi tạo AgentLoop
    var agent = agent_mod.AgentLoop.init(alloc, &cfg) catch |e| {
        stderrPrint("Lỗi init agent: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer agent.deinit();

    // Override backend từ CLI
    if (args.backend) |b| agent.switchBackend(b, null);

    // Single-shot mode
    if (args.prompt) |prompt| {
        try agent.processInput(prompt, printText);
        return;
    }

    // Single-shot mode from file
    if (args.single) |prompt_file| {
        const file = std.fs.cwd().openFile(prompt_file, .{}) catch |e| {
            stderrPrint("Không mở được prompt file '{s}': {s}\n", .{ prompt_file, @errorName(e) });
            std.process.exit(1);
        };
        defer file.close();
        const stat = try file.stat();
        const file_buf = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(file_buf);
        const n = try utils.readAll(file, file_buf);
        const file_prompt = std.mem.trim(u8, file_buf[0..n], " \t\r\n");
        try agent.processInput(file_prompt, printText);
        return;
    }

    // REPL mode
    try runRepl(alloc, &agent);
}

// ---------------------------------------------------------------------------
// REPL
// ---------------------------------------------------------------------------

fn runRepl(alloc: Allocator, agent: *agent_mod.AgentLoop) !void {
    _ = alloc;
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    stdoutPrint("\x1b[1;32mmini-agent\x1b[0m {s} | {s} ({s})\n", .{
        VERSION, agent.backend.name(), agent.backend.model(),
    });
    try stdout.writeAll("Gõ /help để xem lệnh, /quit để thoát.\n\n");

    var line_buf: [8192]u8 = undefined;
    while (true) {
        // Hiển thị prompt
        try stdout.writeAll(PROMPT_PREFIX);

        const line = readLine(stdin, &line_buf) orelse break;
        const input = std.mem.trim(u8, line, " \t");
        if (input.len == 0) continue;

        // Slash commands
        if (input[0] == '/') {
            if (handleSlashCommand(agent, input)) continue else break;
        }

        // Gửi đến agent
        agent.processInput(input, printText) catch |e| {
            stdoutPrint("\x1b[31m[lỗi]\x1b[0m {s}\n", .{@errorName(e)});
        };
    }

    try stdout.writeAll("\nTạm biệt!\n");
}

/// Xử lý slash command. Trả về true để tiếp tục, false để thoát.
fn handleSlashCommand(agent: *agent_mod.AgentLoop, input: []const u8) bool {
    if (std.mem.eql(u8, input, "/quit") or
        std.mem.eql(u8, input, "/exit") or
        std.mem.eql(u8, input, "/q"))
    {
        return false;
    }

    if (std.mem.eql(u8, input, "/clear")) {
        agent.clearHistory();
        std.fs.File.stdout().writeAll("\x1b[2J\x1b[H") catch {};
        std.fs.File.stdout().writeAll("[Lịch sử đã xóa]\n") catch {};
        return true;
    }

    if (std.mem.eql(u8, input, "/help")) {
        std.fs.File.stdout().writeAll(
            \\
            \\## Lệnh REPL
            \\  /clear              Xóa lịch sử hội thoại
            \\  /model <backend>    Đổi backend (openai, claude, ollama)
            \\  /quit, /exit, /q    Thoát
            \\  /help               Hiện hướng dẫn này
            \\
            \\## Tools có sẵn
            \\  bash, file_read, file_write, file_edit
            \\  glob, grep, http_request, web_search, skills
            \\
        ) catch {};
        return true;
    }

    if (std.mem.startsWith(u8, input, "/model ")) {
        const backend_arg = std.mem.trim(u8, input["/model ".len..], " \t");
        if (std.mem.indexOfScalar(u8, backend_arg, ' ')) |space| {
            agent.switchBackend(backend_arg[0..space], backend_arg[space + 1 ..]);
        } else {
            agent.switchBackend(backend_arg, null);
        }
        return true;
    }

    stdoutPrint("Lệnh không hợp lệ: {s}. Gõ /help để xem danh sách.\n", .{input});
    return true;
}

// ---------------------------------------------------------------------------
// Args parsing
// ---------------------------------------------------------------------------

const Args = struct {
    prompt: ?[]const u8 = null,
    single: ?[]const u8 = null,
    system_file: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    no_mcp: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

fn parseArgs(args: []const []const u8) !Args {
    var result = Args{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec")) {
            i += 1;
            if (i < args.len) result.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--single")) {
            i += 1;
            if (i < args.len) result.single = args[i];
        } else if (std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i < args.len) result.system_file = args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) result.backend = args[i];
        } else if (std.mem.eql(u8, arg, "--no-mcp")) {
            result.no_mcp = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.show_version = true;
        } else if (arg.len > 0 and arg[0] != '-' and result.prompt == null) {
            result.prompt = arg;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Streaming callback
// ---------------------------------------------------------------------------

fn printText(text: []const u8) void {
    std.fs.File.stdout().writeAll(text) catch {};
}

// ---------------------------------------------------------------------------
// Help text
// ---------------------------------------------------------------------------

fn printHelp() void {
    std.fs.File.stdout().writeAll(
        \\mini-agent — AI agent trên terminal
        \\
        \\CÁCH DÙNG:
        \\  mini-agent [options]
        \\
        \\OPTIONS:
        \\  -e, --exec <prompt>    Chạy single-shot và thoát
        \\  --system <file>        Dùng file làm system prompt
        \\  --model <backend>      Chọn backend: openai, claude, ollama
        \\  --no-mcp               Không kết nối MCP servers
        \\  --version, -v          In phiên bản
        \\  --help, -h             In hướng dẫn này
        \\
        \\VÍ DỤ:
        \\  mini-agent -e "Tóm tắt README.md"
        \\  mini-agent --system prompt.md
        \\  mini-agent --model claude
        \\  MINI_TOOL_BLOCKLIST=bash mini-agent
        \\
        \\CẤU HÌNH (.env hoặc biến môi trường):
        \\  OPENAI_COMPAT_URL      URL OpenAI-compatible
        \\  OPENAI_COMPAT_MODEL    Tên model
        \\  OPENAI_COMPAT_API_HEADER Header tên (mặc định: Authorization)
        \\  ANTHROPIC_API_KEY      Claude API key
        \\  OLLAMA_HOST            Ollama URL (mặc định: localhost:11434)
        \\  MINI_SYSTEM_FILE       System prompt file
        \\  MINI_TOOL_ALLOWLIST    Chỉ cho phép tools này (comma-separated)
        \\  MINI_TOOL_BLOCKLIST    Chặn tools này (comma-separated)
        \\  MINI_MCP_CONFIG        Đường dẫn mcp.json
        \\
    ) catch {};
}
