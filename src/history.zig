//! history.zig — Lịch sử hội thoại in-memory.
//!
//! Quản lý danh sách các `Message` trong một phiên hội thoại.
//! Tự động compact khi số lượng tin nhắn vượt ngưỡng để tránh
//! overflow context window của AI model.
//!
//! ## Cách dùng
//! ```zig
//! var h = History.init(alloc);
//! defer h.deinit();
//! try h.addUser("Xin chào!");
//! try h.addAssistant("Chào bạn!");
//! const msgs = h.messages();  // gửi lên API
//! ```
//!
//! ## Compact
//! Khi `messages.len > max_messages`, gọi `compact()` để giữ lại
//! chỉ một nửa số tin nhắn gần nhất (tính theo cặp user/assistant).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const proto = @import("protocol.zig");

/// Số tin nhắn tối đa trước khi tự động compact.
const DEFAULT_MAX_MESSAGES = 40;

/// Lịch sử hội thoại cho một phiên làm việc.
pub const History = struct {
    alloc: Allocator,
    msgs: ArrayList(proto.Message),
    /// Ngưỡng tự động compact.
    max_messages: usize,

    /// Khởi tạo History rỗng.
    pub fn init(alloc: Allocator) History {
        return .{
            .alloc = alloc,
            .msgs = ArrayList(proto.Message){},
            .max_messages = DEFAULT_MAX_MESSAGES,
        };
    }

    fn freeContentBlocks(alloc: Allocator, blocks: []const proto.ContentBlock) void {
        for (blocks) |block| {
            switch (block) {
                .text => |t| alloc.free(t),
                .tool_use => |tu| {
                    alloc.free(tu.id);
                    alloc.free(tu.name);
                    alloc.free(tu.input_json);
                },
                .tool_result => |tr| {
                    alloc.free(tr.tool_use_id);
                    alloc.free(tr.content);
                },
            }
        }
        alloc.free(blocks);
    }

    /// Giải phóng tất cả bộ nhớ.
    pub fn deinit(self: *History) void {
        for (self.msgs.items) |msg| {
            freeContentBlocks(self.alloc, msg.content);
        }
        self.msgs.deinit(self.alloc);
    }

    /// Thêm tin nhắn của user.
    /// `text` được copy vào bộ nhớ sở hữu bởi History.
    pub fn addUser(self: *History, text: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, text);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = text_copy };
        try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks });
        try self.maybeCompact();
    }

    /// Thêm tin nhắn của assistant (text response).
    pub fn addAssistantText(self: *History, text: []const u8) !void {
        const text_copy = try self.alloc.dupe(u8, text);
        const blocks = try self.alloc.alloc(proto.ContentBlock, 1);
        blocks[0] = .{ .text = text_copy };
        try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks });
    }

    /// Thêm phản hồi đầy đủ từ AI (có thể chứa text + tool_use).
    /// Content blocks được copy sâu vào History. Trả về true nếu tin nhắn được thêm.
    pub fn addAssistantResponse(self: *History, response: *const proto.Response) !bool {
        if (response.content.items.len == 0) return false;
        const blocks = try self.alloc.alloc(proto.ContentBlock, response.content.items.len);
        for (response.content.items, 0..) |block, i| {
            blocks[i] = switch (block) {
                .text => |t| .{ .text = try self.alloc.dupe(u8, t) },
                .tool_use => |tu| .{ .tool_use = .{
                    .id = try self.alloc.dupe(u8, tu.id),
                    .name = try self.alloc.dupe(u8, tu.name),
                    .input_json = try self.alloc.dupe(u8, tu.input_json),
                }},
                .tool_result => |tr| .{ .tool_result = .{
                    .tool_use_id = try self.alloc.dupe(u8, tr.tool_use_id),
                    .content = try self.alloc.dupe(u8, tr.content),
                    .is_error = tr.is_error,
                }},
            };
        }
        try self.msgs.append(self.alloc, .{ .role = .assistant, .content = blocks });
        return true;
    }

    /// Thêm kết quả tool execution vào lịch sử (dạng user message với tool_result blocks).
    pub fn addToolResults(self: *History, results: []const proto.ToolResult) !void {
        if (results.len == 0) return;
        const blocks = try self.alloc.alloc(proto.ContentBlock, results.len);
        for (results, 0..) |r, i| {
            blocks[i] = .{ .tool_result = .{
                .tool_use_id = try self.alloc.dupe(u8, r.tool_use_id),
                .content = try self.alloc.dupe(u8, r.content),
                .is_error = r.is_error,
            }};
        }
        try self.msgs.append(self.alloc, .{ .role = .user, .content = blocks });
    }

    /// Trả về slice tin nhắn hiện tại (không owned).
    pub fn messages(self: *const History) []const proto.Message {
        return self.msgs.items;
    }

    /// Số tin nhắn hiện tại.
    pub fn len(self: *const History) usize {
        return self.msgs.items.len;
    }

    /// Xóa toàn bộ lịch sử.
    pub fn clear(self: *History) void {
        for (self.msgs.items) |msg| freeContentBlocks(self.alloc, msg.content);
        self.msgs.clearRetainingCapacity();
    }

    /// Xóa tin nhắn cuối cùng khỏi lịch sử.
    pub fn popLast(self: *History) void {
        if (self.msgs.items.len == 0) return;
        const last = self.msgs.items[self.msgs.items.len - 1];
        freeContentBlocks(self.alloc, last.content);
        self.msgs.items.len -= 1;
    }

    /// Compact: giữ lại chỉ một nửa các tin nhắn gần nhất.
    /// Luôn giữ theo cặp chẵn (user + assistant) để không phá vỡ cấu trúc.
    pub fn compact(self: *History) void {
        const n = self.msgs.items.len;
        if (n <= 2) return;

        // Giữ lại nửa sau, tính theo bội số 2
        const keep = (n / 2) & ~@as(usize, 1); // làm tròn xuống số chẵn
        const drop = n - keep;

        // Free các message bị bỏ
        for (self.msgs.items[0..drop]) |msg| freeContentBlocks(self.alloc, msg.content);

        // Shift left
        std.mem.copyForwards(proto.Message, self.msgs.items[0..keep], self.msgs.items[drop..]);
        self.msgs.items.len = keep;

        std.debug.print("[history] Compacted: giữ {d}/{d} messages\n", .{ keep, n });
    }

    /// Compact tự động nếu vượt ngưỡng.
    fn maybeCompact(self: *History) !void {
        if (self.msgs.items.len > self.max_messages) self.compact();
    }
};
