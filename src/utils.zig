//! utils.zig — Các hàm tiện ích dùng chung cho mini-agent.
//!
//! Bao gồm các wrapper giúp tương thích với Zig 0.15.2 trong đó
//! một số API cũ (readAll, deprecatedWriter, ArrayList.writer()) đã bị xóa.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Đọc toàn bộ nội dung file vào buffer đã cấp phát.
/// Tương đương File.readAll() đã bị xóa trong Zig 0.15.2.
pub fn readAll(file: std.fs.File, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// Đọc một dòng byte-by-byte từ File, bỏ '\r'. Trả về null nếu EOF.
pub fn readLine(file: std.fs.File, buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = file.read(&byte) catch return null;
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
// BufWriter — thay thế ArrayList(u8).writer() đã bị xóa trong Zig 0.15.2
// ---------------------------------------------------------------------------

/// Growable string buffer với API print/writeAll/writeByte.
/// Thay thế pattern `buf.writer(alloc)` đã không còn hoạt động.
pub const BufWriter = struct {
    list: std.ArrayList(u8),
    alloc: Allocator,

    pub fn init(alloc: Allocator) BufWriter {
        return .{
            .list = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *BufWriter) void {
        self.list.deinit(self.alloc);
    }

    /// Append formatted string.
    pub fn print(self: *BufWriter, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.list.appendSlice(self.alloc, s);
    }

    /// Append raw bytes.
    pub fn writeAll(self: *BufWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }

    /// Append một byte.
    pub fn writeByte(self: *BufWriter, byte: u8) !void {
        try self.list.append(self.alloc, byte);
    }

    /// Trả về nội dung (owned slice). Caller phải free.
    pub fn toOwnedSlice(self: *BufWriter) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};
