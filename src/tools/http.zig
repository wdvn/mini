//! tools/http.zig — Tool gửi HTTP request tới bất kỳ URL.
//!
//! Wrapper đơn giản quanh libcurl, hỗ trợ các phương thức HTTP phổ biến
//! và custom headers. Response body được truncate ở 30KB để tránh
//! overflow context window của AI.
//!
//! ## Input schema
//! ```json
//! {
//!   "url": "https://api.example.com/data",
//!   "method": "POST",
//!   "body": "{\"key\":\"value\"}",
//!   "headers": {"Authorization": "Bearer token", "Content-Type": "application/json"}
//! }
//! ```
//!
//! ## Output
//! ```
//! HTTP 200
//! Content-Type: application/json
//!
//! {"result":"ok"}
//! ```
//!
//! ## Phụ thuộc
//! libcurl — được link trong build.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const utils = @import("../utils.zig");

const MAX_RESPONSE_SIZE = 30 * 1024;

// ---------------------------------------------------------------------------
// libcurl
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_CUSTOMREQUEST: c_int = 10036;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_HEADERFUNCTION: c_int = 20079;
const CURLOPT_HEADERDATA: c_int = 10029;
const CURLOPT_SSL_VERIFYPEER: c_int = 64;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_FOLLOWLOCATION: c_int = 52;
const CURLOPT_NOBODY: c_int = 44;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;
const CURLE_OK: c_int = 0;

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) c_int;
extern fn curl_easy_perform(handle: *CURL) c_int;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) c_int;
extern fn curl_easy_strerror(code: c_int) [*:0]const u8;
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: ?*CurlSlist) void;

// ---------------------------------------------------------------------------
// Tool entry point
// ---------------------------------------------------------------------------

/// Thực thi tool http_request.
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    const url = json.findString(input_json, "url") orelse
        return std.fmt.allocPrint(alloc, "Lỗi: thiếu trường 'url'", .{});
    const method = json.findString(input_json, "method") orelse "GET";
    const body = json.findString(input_json, "body");
    // headers là object, parse thủ công
    const headers_json = json.findObject(input_json, "headers");

    return httpRequest(alloc, url, method, body, headers_json);
}

/// Gửi HTTP request và trả về status + headers + body.
pub fn httpRequest(
    alloc: Allocator,
    url: []const u8,
    method: []const u8,
    body: ?[]const u8,
    headers_json: ?[]const u8,
) ![]u8 {
    const curl = curl_easy_init() orelse return error.CurlInitFailed;
    defer curl_easy_cleanup(curl);

    // URL
    var url_z: [2048]u8 = undefined;
    if (url.len >= url_z.len) return std.fmt.allocPrint(alloc, "URL quá dài", .{});
    @memcpy(url_z[0..url.len], url);
    url_z[url.len] = 0;
    _ = curl_easy_setopt(curl, CURLOPT_URL, &url_z);

    // Method
    var method_z: [32]u8 = undefined;
    const mu = std.ascii.upperString(&method_z, method[0..@min(method.len, 31)]);
    method_z[mu.len] = 0;
    _ = curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, &method_z);

    // Body
    if (body) |b| {
        if (b.len > 0) {
            _ = curl_easy_setopt(curl, CURLOPT_POSTFIELDS, b.ptr);
            _ = curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)));
        }
    }

    // HEAD method
    if (std.mem.eql(u8, method, "HEAD")) {
        _ = curl_easy_setopt(curl, CURLOPT_NOBODY, @as(c_long, 1));
    }

    // Follow redirects
    _ = curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    // Build headers slist
    var slist: ?*CurlSlist = null;
    defer if (slist) |s| curl_slist_free_all(s);

    var hdr_buf: [4096]u8 = undefined;

    // Parse headers từ JSON object: {"Key":"Value","Key2":"Value2"}
    if (headers_json) |hj| {
        var i: usize = 1; // skip {
        while (i < hj.len) : (i += 1) {
            if (hj[i] == '"') {
                const key_start = i + 1;
                i += 1;
                while (i < hj.len and hj[i] != '"') : (i += 1) {}
                const key = hj[key_start..i];
                // Skip ":"
                i += 1;
                while (i < hj.len and (hj[i] == ':' or hj[i] == ' ')) : (i += 1) {}
                if (i < hj.len and hj[i] == '"') {
                    const val_start = i + 1;
                    i += 1;
                    while (i < hj.len and hj[i] != '"') : (i += 1) {}
                    const val = hj[val_start..i];
                    const h = std.fmt.bufPrint(&hdr_buf, "{s}: {s}", .{ key, val }) catch continue;
                    if (h.len < hdr_buf.len) {
                        hdr_buf[h.len] = 0;
                        slist = curl_slist_append(slist, hdr_buf[0..h.len :0].ptr);
                    }
                }
            }
        }
    }
    if (slist) |s| _ = curl_easy_setopt(curl, CURLOPT_HTTPHEADER, s);

    // Misc
    _ = curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    _ = curl_easy_setopt(curl, CURLOPT_TIMEOUT, @as(c_long, 30));

    // Response collectors via BufCtx
    var resp_body = std.ArrayListUnmanaged(u8){};
    defer resp_body.deinit(alloc);
    var resp_headers = std.ArrayListUnmanaged(u8){};
    defer resp_headers.deinit(alloc);

    var body_ctx = BufCtx{ .alloc = alloc, .buf = &resp_body };
    var hdr_ctx  = BufCtx{ .alloc = alloc, .buf = &resp_headers };

    _ = curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, bodyCallback);
    _ = curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body_ctx);
    _ = curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, headerCallback);
    _ = curl_easy_setopt(curl, CURLOPT_HEADERDATA, &hdr_ctx);

    const rc = curl_easy_perform(curl);
    if (rc != CURLE_OK) {
        return std.fmt.allocPrint(alloc, "Lỗi curl: {s}", .{curl_easy_strerror(rc)});
    }

    var http_code: c_long = 0;
    _ = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    // Build formatted output
    var out = utils.BufWriter.init(alloc);
    errdefer out.deinit();
    const w = &out;

    try w.print("HTTP {d}\n", .{http_code});
    var hlines = std.mem.splitScalar(u8, resp_headers.items, '\n');
    while (hlines.next()) |hline| {
        const hl = std.mem.trim(u8, hline, " \t\r");
        if (hl.len == 0) continue;
        if (std.mem.startsWith(u8, hl, "HTTP/")) continue;
        try w.print("{s}\n", .{hl});
    }
    try w.writeByte('\n');

    const body_slice = resp_body.items[0..@min(resp_body.items.len, MAX_RESPONSE_SIZE)];
    try w.writeAll(body_slice);
    if (resp_body.items.len > MAX_RESPONSE_SIZE) {
        try w.print("\n... [truncated {d} bytes]", .{resp_body.items.len - MAX_RESPONSE_SIZE});
    }

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Curl callbacks
// ---------------------------------------------------------------------------

/// Struct truyền allocator + buffer vào curl write callback.
const BufCtx = struct {
    alloc: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
};

fn bodyCallback(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.{ .x86_64_sysv = .{} }) usize {
    const n = size * nmemb;
    const ctx: *BufCtx = @ptrCast(@alignCast(userdata.?));
    if (ctx.buf.items.len < MAX_RESPONSE_SIZE) {
        ctx.buf.appendSlice(ctx.alloc, ptr[0..n]) catch {};
    }
    return n;
}

fn headerCallback(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.{ .x86_64_sysv = .{} }) usize {
    const n = size * nmemb;
    const ctx: *BufCtx = @ptrCast(@alignCast(userdata.?));
    ctx.buf.appendSlice(ctx.alloc, ptr[0..n]) catch {};
    return n;
}

