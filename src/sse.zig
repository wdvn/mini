//! sse.zig — HTTP client dùng libcurl, hỗ trợ streaming SSE và NDJSON.
//!
//! Module này cung cấp hàm `post` duy nhất để gửi HTTP POST đến bất kỳ
//! endpoint nào và nhận phản hồi theo từng chunk qua callback.
//!
//! Các AI backend (openai, claude, ollama) dùng module này làm tầng vận chuyển,
//! mỗi backend tự parse chunk theo định dạng riêng của mình.
//!
//! ## Phụ thuộc
//!   - libcurl (được link trong build.zig)
//!
//! ## Cách dùng
//! ```zig
//! var ctx = MyCtx{};
//! const status = try sse.post(alloc, .{
//!     .url = "https://api.example.com/v1/chat",
//!     .headers = &.{ "Authorization: Bearer sk-...", "Content-Type: application/json" },
//!     .body = json_body,
//!     .timeout_secs = 120,
//! }, MyCtx.onChunk, &ctx);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// libcurl extern declarations
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

const CURLE_OK: c_int = 0;

// Option codes từ curl.h
const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_POST: c_int = 47;
const CURLOPT_SSL_VERIFYPEER: c_int = 64;
const CURLOPT_TIMEOUT: c_int = 13;
const CURLOPT_CONNECTTIMEOUT: c_int = 78;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) c_int;
extern fn curl_easy_perform(handle: *CURL) c_int;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) c_int;
extern fn curl_easy_strerror(code: c_int) [*:0]const u8;
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: ?*CurlSlist) void;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Hàm callback nhận từng chunk dữ liệu từ HTTP response.
/// `chunk` là slice tạm thời — phải copy nếu cần giữ lại.
/// `userdata` là con trỏ tới context struct của caller.
pub const ChunkFn = *const fn (chunk: []const u8, userdata: *anyopaque) void;

/// Tùy chọn cho HTTP request.
pub const RequestOpts = struct {
    /// URL đầy đủ (phải có http:// hoặc https://).
    url: []const u8,
    /// Headers dạng "Key: Value".
    headers: []const []const u8 = &.{},
    /// Body của POST request (JSON string).
    body: []const u8 = "",
    /// Timeout tổng (giây). Mặc định: 300.
    timeout_secs: u32 = 300,
};

/// Gửi HTTP POST và nhận phản hồi qua `on_chunk` callback.
/// Trả về HTTP status code.
/// Lỗi: CurlInitFailed, CurlError.
pub fn post(
    _: Allocator, // reserved cho tương lai (pooling)
    opts: RequestOpts,
    on_chunk: ChunkFn,
    userdata: *anyopaque,
) !u32 {
    const curl = curl_easy_init() orelse return error.CurlInitFailed;
    defer curl_easy_cleanup(curl);

    // URL (null-terminated)
    var url_buf: [2048]u8 = undefined;
    if (opts.url.len >= url_buf.len) return error.UrlTooLong;
    @memcpy(url_buf[0..opts.url.len], opts.url);
    url_buf[opts.url.len] = 0;
    _ = curl_easy_setopt(curl, CURLOPT_URL, &url_buf);

    // Headers
    var slist: ?*CurlSlist = null;
    defer if (slist) |s| curl_slist_free_all(s);

    var hdr_buf: [4096]u8 = undefined;
    for (opts.headers) |hdr| {
        if (hdr.len >= hdr_buf.len) continue;
        @memcpy(hdr_buf[0..hdr.len], hdr);
        hdr_buf[hdr.len] = 0;
        slist = curl_slist_append(slist, hdr_buf[0..hdr.len :0].ptr);
    }
    if (slist) |s| _ = curl_easy_setopt(curl, CURLOPT_HTTPHEADER, s);

    // POST body
    if (opts.body.len > 0) {
        _ = curl_easy_setopt(curl, CURLOPT_POST, @as(c_long, 1));
        _ = curl_easy_setopt(curl, CURLOPT_POSTFIELDS, opts.body.ptr);
        _ = curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(opts.body.len)));
    }

    // Write callback
    const ctx = WriteCtx{ .on_chunk = on_chunk, .userdata = userdata };
    _ = curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    _ = curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);

    // Misc
    _ = curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    _ = curl_easy_setopt(curl, CURLOPT_TIMEOUT, @as(c_long, opts.timeout_secs));
    _ = curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));

    const rc = curl_easy_perform(curl);
    if (rc != CURLE_OK) {
        std.debug.print("[sse] curl error: {s}\n", .{curl_easy_strerror(rc)});
        return error.CurlError;
    }

    var http_code: c_long = 0;
    _ = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    return @intCast(http_code);
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

const WriteCtx = struct {
    on_chunk: ChunkFn,
    userdata: *anyopaque,
};

fn writeCallback(
    ptr: [*c]u8,
    size: usize,
    nmemb: usize,
    userdata: ?*anyopaque,
) callconv(.{ .x86_64_sysv = .{} }) usize {
    const n = size * nmemb;
    if (n == 0) return 0;
    const ctx: *const WriteCtx = @ptrCast(@alignCast(userdata.?));
    ctx.on_chunk(ptr[0..n], ctx.userdata);
    return n;
}
