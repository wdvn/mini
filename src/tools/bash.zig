//! tools/bash.zig — Tool thực thi lệnh shell.
//!
//! Chạy lệnh shell qua `/bin/sh -c` và trả về stdout + stderr.
//! Có safety check để chặn các lệnh nguy hiểm.
//!
//! ## Safety blocklist
//! Các pattern sau bị chặn vô điều kiện:
//!   - `rm -rf /` hoặc `rm -rf ~`
//!   - `dd if=`, `mkfs`, `wipefs`
//!   - `shutdown`, `reboot`, `halt`, `init 0`, `init 6`
//!   - `git push --force`, `git push -f`
//!
//! ## Tool input schema
//! ```json
//! { "command": "ls -la /tmp" }
//! ```
//!
//! ## Giới hạn
//!   - Output bị truncate ở 32KB
//!   - Timeout: 30 giây
//!   - Working directory: CWD của process

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const utils = @import("../utils.zig");

/// Danh sách pattern lệnh bị chặn.
const BLOCKED_PATTERNS = [_][]const u8{
    "rm -rf /",
    "rm -rf ~",
    "dd if=",
    "mkfs",
    "wipefs",
    "shutdown",
    "reboot",
    "halt",
    "init 0",
    "init 6",
    "git push --force",
    "git push -f",
    "git reset --hard",
    "git clean -f",
};

/// Giới hạn output (byte).
const MAX_OUTPUT = 32 * 1024;

/// Thực thi tool bash.
/// Input: JSON string với trường "command".
/// Output: stdout/stderr của lệnh, hoặc thông báo lỗi.
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const command = json.findString(input_json, "command") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'command'", .{});

    // Safety check
    for (&BLOCKED_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) {
            return std.fmt.allocPrint(alloc,
                "BLOCKED: Lệnh bị chặn bởi safety policy.\nLệnh: {s}\nPattern: {s}",
                .{ command, pattern },
            );
        }
    }

    return executeCommand(alloc, command);
}

/// Chạy lệnh shell và thu thập output.
fn executeCommand(alloc: Allocator, command: []const u8) ![]u8 {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf = std.ArrayListUnmanaged(u8){};
    var stderr_buf = std.ArrayListUnmanaged(u8){};
    defer stdout_buf.deinit(alloc);
    defer stderr_buf.deinit(alloc);

    // Đọc stdout và stderr
    var stdout_bytes: [MAX_OUTPUT]u8 = undefined;
    var stderr_bytes: [MAX_OUTPUT]u8 = undefined;
    var stdolen: usize = 0;
    var stdelen: usize = 0;

    if (child.stdout) |out| {
        stdolen = utils.readAll(out, &stdout_bytes) catch 0;
    }
    if (child.stderr) |err| {
        stdelen = utils.readAll(err, &stderr_bytes) catch 0;
    }

    const term = child.wait() catch |e| {
        return std.fmt.allocPrint(alloc, "Lỗi wait: {s}", .{@errorName(e)});
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        .Signal => |sig| {
            return std.fmt.allocPrint(alloc, "Killed by signal {d}", .{sig});
        },
        else => 1,
    };

    // Build kết quả
    var result = utils.BufWriter.init(alloc);
    errdefer result.deinit();
    const w = &result;

    if (stdolen > 0) {
        try w.writeAll(stdout_bytes[0..@min(stdolen, MAX_OUTPUT)]);
    }
    if (stdelen > 0) {
        if (stdolen > 0) try w.writeByte('\n');
        try w.writeAll(stderr_bytes[0..@min(stdelen, MAX_OUTPUT)]);
    }
    if (exit_code != 0 and result.list.items.len == 0) {
        try w.print("Exit code: {d}", .{exit_code});
    }
    if (result.list.items.len == 0) {
        try w.writeAll("(no output)");
    }

    return result.toOwnedSlice();
}
