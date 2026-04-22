//! agent.zig — AgentLoop: vòng lặp chính của mini-agent.
//!
//! AgentLoop xử lý một user input qua nhiều iterations cho đến khi
//! AI trả về `end_turn` (không còn muốn gọi tool).
//!
//! ## Luồng một iteration
//! ```
//! user_text → history.addUser()
//!           → sendToBackend(system, history, tools)  ← streaming
//!           → response.stop_reason == .tool_use?
//!               YES → executeTools() → history.addToolResults() → tiếp tục
//!               NO  → kết thúc, trả về
//! ```
//!
//! ## Backends
//! Agent ưu tiên backend theo thứ tự:
//!   1. OpenAI-compatible (nếu có OPENAI_COMPAT_URL)
//!   2. Claude (nếu có ANTHROPIC_API_KEY)
//!   3. Ollama (fallback local)
//!
//! ## Fallback
//! Nếu primary backend lỗi, agent thử các backend còn lại.
//!
//! ## Giới hạn
//! Tối đa `MAX_ITERATIONS` iterations mỗi lần gọi processInput.
//! Ngăn vòng lặp vô tận khi AI liên tục gọi tool.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");
const config_mod = @import("config.zig");
const history_mod = @import("history.zig");
const tools_mod = @import("tools.zig");
const json_mod = @import("json.zig");
const openai_mod = @import("backend/openai.zig");
const claude_mod = @import("backend/claude.zig");
const ollama_mod = @import("backend/ollama.zig");

/// Số iterations tối đa trong một lần processInput.
const MAX_ITERATIONS = 100;
/// Số lần retry tối đa khi gặp rate limit.
const MAX_RATE_LIMIT_RETRIES = 5;
/// Thời gian chờ ban đầu khi gặp rate limit (giây).
const RATE_LIMIT_BASE_DELAY_S: u64 = 5;

pub const AgentError = error{
    MaxIterationsReached,
};

// ---------------------------------------------------------------------------
// Backend union
// ---------------------------------------------------------------------------

/// Backend AI đang sử dụng.
pub const Backend = union(enum) {
    openai: openai_mod.Client,
    claude: claude_mod.Client,
    ollama: ollama_mod.Client,

    /// Tên hiển thị của backend.
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .openai => "openai-compat",
            .claude => "claude",
            .ollama => "ollama",
        };
    }

    /// Tên model đang dùng.
    pub fn model(self: Backend) []const u8 {
        return switch (self) {
            .openai => |c| c.model,
            .claude => |c| c.model,
            .ollama => |c| c.model,
        };
    }

    /// Gửi message đến backend. Trả về Response đầy đủ.
    fn send(
        self: *Backend,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        return switch (self.*) {
            .openai => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb),
            .claude => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb),
            .ollama => |*c| c.sendMessage(system_prompt, msgs, tool_defs, text_cb),
        };
    }
};

// ---------------------------------------------------------------------------
// AgentLoop
// ---------------------------------------------------------------------------

/// Vòng lặp agent chính.
pub const AgentLoop = struct {
    alloc: Allocator,
    /// Backend đang sử dụng.
    backend: Backend,
    /// Lịch sử hội thoại.
    history: history_mod.History,
    /// Config đã load.
    config: *const config_mod.Config,

    /// Khởi tạo AgentLoop từ config.
    /// Chọn backend dựa trên config theo thứ tự ưu tiên.
    pub fn init(alloc: Allocator, config: *const config_mod.Config) !AgentLoop {
        // Chọn backend theo thứ tự ưu tiên
        const backend: Backend = blk: {
            if (config.openai_compat_url) |url| {
                std.debug.print("[agent] Backend: OpenAI-compat @ {s} ({s})\n", .{ url, config.openai_compat_model });
                break :blk .{ .openai = openai_mod.Client.init(
                    alloc,
                    url,
                    config.openai_compat_key orelse "",
                    config.openai_compat_api_header,
                    config.openai_compat_model,
                    config.max_tokens,
                ) };
            }
            if (config.anthropic_key) |key| {
                std.debug.print("[agent] Backend: Claude ({s})\n", .{config.claude_model});
                break :blk .{ .claude = claude_mod.Client.init(
                    alloc,
                    key,
                    config.claude_model,
                    config.max_tokens,
                ) };
            }
            // Fallback: Ollama
            std.debug.print("[agent] Backend: Ollama @ {s} ({s})\n", .{ config.ollama_url, config.ollama_model });
            break :blk .{ .ollama = ollama_mod.Client.init(
                alloc,
                config.ollama_url,
                config.ollama_model,
                config.max_tokens,
            ) };
        };

        // Thiết lập tool policy
        tools_mod.setPolicy(config.tool_allowlist, config.tool_blocklist);

        return .{
            .alloc = alloc,
            .backend = backend,
            .history = history_mod.History.init(alloc),
            .config = config,
        };
    }

    /// Giải phóng bộ nhớ.
    pub fn deinit(self: *AgentLoop) void {
        self.history.deinit();
    }

    /// Xử lý input của user qua agentic loop.
    /// `text_cb`: được gọi với mỗi text chunk khi AI đang stream.
    pub fn processInput(
        self: *AgentLoop,
        user_text: []const u8,
        text_cb: ?*const fn ([]const u8) void,
    ) !void {
        // Thêm user message vào history
        try self.history.addUser(user_text);

        // Lấy danh sách tools phù hợp với user message
        const tool_defs = tools_mod.getRelevantDefinitions(self.alloc, user_text);

        var iteration: usize = 0;
        var rate_limit_retries: usize = 0;
        while (iteration < MAX_ITERATIONS) : (iteration += 1) {
            if (iteration > 0) {
                std.debug.print("\x1b[90m[agent] --- Vòng lặp {d} ---\x1b[0m\n", .{iteration + 1});
            } else {
                std.debug.print("\n\x1b[90m[agent] --- Bắt đầu quy trình ---\x1b[0m\n", .{});
            }

            std.debug.print("\x1b[36m[agent]\x1b[0m \x1b[93mĐang suy nghĩ / Phân tích yêu cầu... \x1b[0m\n", .{});

            // Gửi lên AI backend (streaming)
            var response = self.sendToBackend(
                self.config.system_prompt,
                self.history.messages(),
                tool_defs,
                text_cb,
            ) catch |e| {
                std.debug.print("\n[agent] API lỗi: {s}\n", .{@errorName(e)});
                return;
            };
            defer response.deinit();

            // Xuống dòng sau khi stream xong
            try std.fs.File.stdout().writeAll("\n");

            // Thêm response vào history (nếu có nội dung)
            const added_to_history = try self.history.addAssistantResponse(&response);

            switch (response.stop_reason) {
                .end_turn, .stop_sequence => {
                    std.debug.print("\n\x1b[92m[agent] ✓ Hoàn thành sau {d} vòng lặp.\x1b[0m\n", .{iteration + 1});
                    return;
                },
                .max_tokens => {
                    std.debug.print("\n\x1b[33m[agent] ⚠️ Cảnh báo: Đạt giới hạn max_tokens. Dừng sớm.\x1b[0m\n", .{});
                    return;
                },
                .tool_use => {
                    try self.executeTools(&response);
                    std.debug.print("\n", .{});
                },
                .unknown => {
                    // Detect rate limit: HTTP 429 or "rate_limit" in raw body
                    const is_rate_limit = blk: {
                        if (response.http_code == 429) break :blk true;
                        if (response.raw_debug_info) |raw| {
                            if (std.mem.indexOf(u8, raw, "rate_limit") != null) break :blk true;
                        }
                        break :blk false;
                    };

                    if (is_rate_limit and rate_limit_retries < MAX_RATE_LIMIT_RETRIES) {
                        rate_limit_retries += 1;
                        const delay = RATE_LIMIT_BASE_DELAY_S * (@as(u64, 1) << @intCast(rate_limit_retries - 1));
                        std.debug.print("\n\x1b[33m[agent] ⚠ Rate limit! Thử lại {d}/{d} sau {d}s...\x1b[0m\n", .{ rate_limit_retries, MAX_RATE_LIMIT_RETRIES, delay });
                        std.Thread.sleep(delay * 1_000_000_000);
                        if (added_to_history) self.history.popLast();
                        continue;
                    }

                    std.debug.print("[agent] Cảnh báo: stop_reason không xác định (HTTP {d})\n", .{response.http_code});
                    if (response.raw_debug_info) |raw| {
                        std.debug.print("\n--- RAW BACKEND RESPONSE ---\n{s}\n----------------------------\n", .{raw});
                    } else {
                        std.debug.print("\n--- RAW BACKEND RESPONSE ---\n(Không có nội dung trả về từ server)\n----------------------------\n", .{});
                    }
                    return;
                },
            }
        }

        std.debug.print("[agent] Đạt giới hạn {d} iterations\n", .{MAX_ITERATIONS});
        return error.MaxIterationsReached;
    }

    /// Xóa lịch sử hội thoại (bắt đầu conversation mới).
    pub fn clearHistory(self: *AgentLoop) void {
        self.history.clear();
    }

    /// Đổi backend tại runtime.
    /// name: "openai", "claude", "ollama"
    pub fn switchBackend(self: *AgentLoop, backend_name: []const u8, model_override: ?[]const u8) void {
        const cfg = self.config;

        if (std.mem.eql(u8, backend_name, "openai") or std.mem.eql(u8, backend_name, "openai-compat")) {
            const url = cfg.openai_compat_url orelse {
                std.debug.print("[agent] OPENAI_COMPAT_URL chưa được thiết lập\n", .{});
                return;
            };
            self.backend = .{ .openai = openai_mod.Client.init(
                self.alloc,
                url,
                cfg.openai_compat_key orelse "",
                cfg.openai_compat_api_header,
                model_override orelse cfg.openai_compat_model,
                cfg.max_tokens,
            ) };
        } else if (std.mem.eql(u8, backend_name, "claude")) {
            const key = cfg.anthropic_key orelse {
                std.debug.print("[agent] ANTHROPIC_API_KEY chưa được thiết lập\n", .{});
                return;
            };
            self.backend = .{ .claude = claude_mod.Client.init(
                self.alloc,
                key,
                model_override orelse cfg.claude_model,
                cfg.max_tokens,
            ) };
        } else if (std.mem.eql(u8, backend_name, "ollama")) {
            self.backend = .{ .ollama = ollama_mod.Client.init(
                self.alloc,
                cfg.ollama_url,
                model_override orelse cfg.ollama_model,
                cfg.max_tokens,
            ) };
        } else {
            std.debug.print("[agent] Backend không hợp lệ: {s}. Chọn: openai, claude, ollama\n", .{backend_name});
            return;
        }

        std.debug.print("[agent] Switched to {s} ({s})\n", .{ self.backend.name(), self.backend.model() });
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn sendToBackend(
        self: *AgentLoop,
        system_prompt: []const u8,
        msgs: []const proto.Message,
        tool_defs: []const proto.ToolDefinition,
        text_cb: ?*const fn ([]const u8) void,
    ) !proto.Response {
        // Primary backend
        const primary = self.backend.send(system_prompt, msgs, tool_defs, text_cb);
        if (primary) |resp| return resp else |e| {
            // Fallback: thử Ollama nếu primary không phải Ollama
            std.debug.print("\n[agent] {s} lỗi ({s}), thử Ollama...\n", .{ self.backend.name(), @errorName(e) });
            if (self.backend != .ollama) {
                var fallback = ollama_mod.Client.init(
                    self.alloc,
                    self.config.ollama_url,
                    self.config.ollama_model,
                    self.config.max_tokens,
                );
                if (fallback.sendMessage(system_prompt, msgs, tool_defs, text_cb)) |resp| {
                    std.debug.print("[agent] Ollama fallback thành công\n", .{});
                    return resp;
                } else |_| {}
            }
            return e;
        }
    }

    /// Thực thi tất cả tool_use blocks trong response.
    fn executeTools(self: *AgentLoop, response: *const proto.Response) !void {
        var results = ArrayList(proto.ToolResult){};
        defer results.deinit(self.alloc);
        
        var allocated_strings = ArrayList([]u8){};
        defer {
            for (allocated_strings.items) |s| self.alloc.free(s);
            allocated_strings.deinit(self.alloc);
        }

        for (response.content.items) |block| {
            switch (block) {
                .tool_use => |tu| {
                    // Hiển thị tên tool và tham số chính (verbose)
                    if (std.mem.eql(u8, tu.name, "bash")) {
                        if (json_mod.findString(tu.input_json, "command")) |cmd| {
                            var cmd_buf: [100]u8 = undefined;
                            const display_cmd = if (cmd.len > 97) std.fmt.bufPrint(&cmd_buf, "{s}...", .{cmd[0..97]}) catch cmd else cmd;
                            std.debug.print("\x1b[90m[bash]\x1b[0m \x1b[35m{s}\x1b[0m ", .{display_cmd});
                        } else {
                            std.debug.print("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                        }
                    } else if (std.mem.eql(u8, tu.name, "file_read") or std.mem.eql(u8, tu.name, "file_write") or std.mem.eql(u8, tu.name, "file_edit")) {
                        if (json_mod.findString(tu.input_json, "path")) |path| {
                            std.debug.print("\x1b[90m[{s}]\x1b[0m \x1b[34m{s}\x1b[0m ", .{tu.name, path});
                        } else {
                            std.debug.print("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                        }
                    } else if (std.mem.eql(u8, tu.name, "web_search")) {
                        if (json_mod.findString(tu.input_json, "query")) |query| {
                            std.debug.print("\x1b[90m[search]\x1b[0m \x1b[32m{s}\x1b[0m ", .{query});
                        } else {
                            std.debug.print("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                        }
                    } else {
                        std.debug.print("\x1b[90m[tool: {s}]\x1b[0m ", .{tu.name});
                    }

                    var is_err = false;
                    const result = tools_mod.executeTool(self.alloc, tu.name, tu.input_json) catch |e| blk: {
                        is_err = true;
                        const msg = try std.fmt.allocPrint(self.alloc, "Lỗi tool: {s}", .{@errorName(e)});
                        break :blk msg;
                    };
                    try allocated_strings.append(self.alloc, result);

                    // Truncate nếu quá lớn
                    const max_tool_result = 64 * 1024;
                    const truncated = if (result.len > max_tool_result) result[0..max_tool_result] else result;

                    try results.append(self.alloc, .{
                        .tool_use_id = tu.id,
                        .content = truncated,
                        .is_error = is_err,
                    });

                    try std.fs.File.stdout().writeAll("\x1b[32m[ok]\x1b[0m\n");
                },
                else => {},
            }
        }

        if (results.items.len > 0) {
            try self.history.addToolResults(results.items);
        }
    }
};
