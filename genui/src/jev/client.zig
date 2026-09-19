const std = @import("std");
const codec = @import("codec.zig");

pub const endpoint = "https://api.typesafe.ai/v1/systemone";
pub const diagnostic_body_bytes_max = 512;
pub const diagnostic_header_bytes_max = 96;

/// `std.http.Client` does not expose decoded TLS transport-byte progress or a
/// body deadline. The caller must run this synchronous transport in a
/// cancellable `std.Io.Future` and cancel it when the caller's deadline fires.
pub const CompletionBound = enum { caller_owned_cancellation_or_deadline };

pub const HttpClassification = enum {
    none,
    success,
    bad_request,
    authentication_failed,
    forbidden,
    not_found,
    invalid_request,
    rate_limited,
    overloaded,
    server_failure,
    unexpected_status,
    protocol_failure,
    transport_failure,
};

pub const BoundedHeader = struct {
    bytes: [diagnostic_header_bytes_max]u8 = undefined,
    len: u8 = 0,
    truncated: bool = false,

    pub fn slice(self: *const BoundedHeader) []const u8 {
        std.debug.assert(self.len <= diagnostic_header_bytes_max);
        std.debug.assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    fn set(self: *BoundedHeader, value: []const u8) void {
        std.debug.assert(self.bytes.len == diagnostic_header_bytes_max);
        std.debug.assert(value.len <= std.math.maxInt(u32));
        const len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..len], value[0..len]);
        self.len = @intCast(len);
        self.truncated = value.len > len;
    }
};

pub const FailureDiagnostics = struct {
    status: ?u16 = null,
    classification: HttpClassification = .none,
    body: [diagnostic_body_bytes_max]u8 = undefined,
    body_len: u16 = 0,
    body_bytes_total: ?u64 = null,
    body_truncated: bool = false,
    request_id: BoundedHeader = .{},
    retry_after: BoundedHeader = .{},
    rate_limit_remaining: BoundedHeader = .{},
    rate_limit_reset: BoundedHeader = .{},

    pub fn reset(self: *FailureDiagnostics) void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(diagnostic_body_bytes_max <= std.math.maxInt(u16));
        self.* = .{};
    }

    pub fn bodySlice(self: *const FailureDiagnostics) []const u8 {
        std.debug.assert(self.body_len <= diagnostic_body_bytes_max);
        std.debug.assert(self.body_len <= self.body.len);
        return self.body[0..self.body_len];
    }

    fn captureBody(self: *FailureDiagnostics, body: []const u8, total: ?u64, truncated: bool) void {
        std.debug.assert(self.body_len <= diagnostic_body_bytes_max);
        std.debug.assert(body.len <= std.math.maxInt(u32));
        const len = @min(body.len, self.body.len);
        @memcpy(self.body[0..len], body[0..len]);
        self.body_len = @intCast(len);
        self.body_bytes_total = total;
        self.body_truncated = truncated or body.len > len;
    }

    fn clearBody(self: *FailureDiagnostics) void {
        std.debug.assert(self.body_len <= diagnostic_body_bytes_max);
        std.debug.assert(self.classification == .success);
        self.body_len = 0;
        self.body_bytes_total = null;
        self.body_truncated = false;
    }
};

pub const HttpRequest = struct {
    url: []const u8,
    authorization: []const u8,
    content_type: []const u8,
    body: []const u8,
};

pub const HttpResponse = struct { status: u16, body: []const u8 };

pub const Transport = struct {
    context: *anyopaque,
    post_fn: *const fn (*anyopaque, *const HttpRequest, []u8, *FailureDiagnostics) anyerror!HttpResponse,
    completion_bound: CompletionBound = .caller_owned_cancellation_or_deadline,
};

pub const Client = struct {
    transport: Transport,

    pub fn evaluate(self: Client, api_key: []const u8, request: *const codec.Request, request_buffer: []u8, response_buffer: []u8, parse_scratch: []u8, diagnostics: *FailureDiagnostics) !codec.Response {
        std.debug.assert(api_key.len > 0);
        std.debug.assert(request.model.len > 0);
        std.debug.assert(self.transport.completion_bound == .caller_owned_cancellation_or_deadline);
        diagnostics.reset();
        var authorization_buffer: [1024]u8 = undefined;
        if (api_key.len + "Bearer ".len > authorization_buffer.len) return error.ApiKeyTooLong;
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{api_key});
        const body = try codec.encodeRequest(request, request_buffer);
        const response = self.transport.post_fn(self.transport.context, &.{
            .url = endpoint,
            .authorization = authorization,
            .content_type = "application/json",
            .body = body,
        }, response_buffer, diagnostics) catch |err| {
            if (diagnostics.status) |status| {
                diagnostics.classification = classificationForStatus(status);
                if (diagnostics.classification == .success) diagnostics.classification = .protocol_failure;
            } else {
                diagnostics.classification = .transport_failure;
            }
            return err;
        };
        diagnostics.status = response.status;
        diagnostics.captureBody(response.body, response.body.len, false);
        try classifyStatus(response.status, diagnostics);
        const result = codec.decodeResponse(response.body, request.questions, parse_scratch) catch |err| {
            diagnostics.classification = .protocol_failure;
            return err;
        };
        diagnostics.clearBody();
        return result;
    }
};

fn classifyStatus(status: u16, diagnostics: *FailureDiagnostics) !void {
    std.debug.assert(diagnostics.status == status);
    std.debug.assert(status >= 100);
    diagnostics.classification = classificationForStatus(status);
    return switch (diagnostics.classification) {
        .success => {},
        .bad_request => error.BadRequest,
        .authentication_failed => error.AuthenticationFailed,
        .forbidden => error.Forbidden,
        .not_found => error.NotFound,
        .invalid_request => error.InvalidRequest,
        .rate_limited => error.RateLimited,
        .overloaded => error.Overloaded,
        .server_failure => error.ServerFailure,
        .unexpected_status => error.UnexpectedHttpStatus,
        else => unreachable,
    };
}

/// Production transport using Zig's TLS-capable HTTP client. The caller owns
/// the allocator and I/O implementation, preserving worker and memory policy.
pub const StdHttpTransport = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    completion_bound: CompletionBound = .caller_owned_cancellation_or_deadline,

    pub fn transport(self: *StdHttpTransport) Transport {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(self.allocator.ptr) != 0);
        return .{ .context = self, .post_fn = post, .completion_bound = self.completion_bound };
    }

    fn post(pointer: *anyopaque, request: *const HttpRequest, response_buffer: []u8, diagnostics: *FailureDiagnostics) !HttpResponse {
        const self: *StdHttpTransport = @ptrCast(@alignCast(pointer));
        std.debug.assert(request.body.len > 0);
        std.debug.assert(response_buffer.len > 0);
        std.debug.assert(self.completion_bound == .caller_owned_cancellation_or_deadline);
        const uri = try std.Uri.parse(request.url);
        var http_client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http_client.deinit();
        var http_request = try http_client.request(.POST, uri, .{
            .keep_alive = false,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .{ .override = request.authorization },
                .content_type = .{ .override = request.content_type },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer http_request.deinit();
        try http_request.sendBodyComplete(@constCast(request.body));

        var redirect_buffer: [8192]u8 = undefined;
        var response = try http_request.receiveHead(&redirect_buffer);
        diagnostics.status = @intFromEnum(response.head.status);
        diagnostics.classification = classificationForStatus(diagnostics.status.?);
        captureHeaders(response.head, diagnostics);
        const content_length = response.head.content_length;
        var transfer_buffer: [8192]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        const bounded_response = response_buffer[0..@min(response_buffer.len, codec.response_bytes_max)];
        const body_len = try readResponseBody(self.io, body_reader, bounded_response, content_length, diagnostics);
        return .{ .status = diagnostics.status.?, .body = response_buffer[0..body_len] };
    }
};

fn readResponseBody(io: std.Io, reader: *std.Io.Reader, output: []u8, content_length: ?u64, diagnostics: *FailureDiagnostics) !usize {
    std.debug.assert(output.len > 0);
    std.debug.assert(output.len <= codec.response_bytes_max);
    var writer = std.Io.Writer.fixed(output);
    // The iteration bound is the caller's cancellable task deadline. Decoded
    // TLS zero reads are valid and therefore cannot be used as a local bound.
    while (writer.end < output.len) {
        if (content_length) |declared| {
            if (writer.end == declared) return finishBody(&writer, declared, diagnostics);
        }
        const limit = bodyReadLimit(writer.end, output.len, content_length);
        const count = reader.stream(&writer, .limited(limit)) catch |err| switch (err) {
            error.EndOfStream => {
                const received: u64 = writer.end;
                if (content_length) |declared| {
                    diagnostics.captureBody(writer.buffered(), declared, received < declared);
                    if (received < declared) return error.ResponseTruncated;
                }
                return finishBody(&writer, received, diagnostics);
            },
            error.ReadFailed => {
                diagnostics.captureBody(writer.buffered(), content_length, true);
                return error.ResponseReadFailed;
            },
            error.WriteFailed => unreachable,
        };
        if (count == 0) {
            try checkBodyCancellation(io, &writer, content_length, diagnostics);
            continue;
        }
        std.debug.assert(writer.end <= output.len);
    }
    if (content_length) |declared| {
        diagnostics.captureBody(writer.buffered(), declared, declared > writer.end);
        if (declared == writer.end) return writer.end;
        return error.ResponseTooLarge;
    }
    return probeResponseEnd(io, reader, &writer, diagnostics);
}

fn checkBodyCancellation(io: std.Io, writer: *std.Io.Writer, content_length: ?u64, diagnostics: *FailureDiagnostics) !void {
    std.debug.assert(writer.end <= codec.response_bytes_max);
    std.debug.assert(diagnostics.status != null);
    io.checkCancel() catch |err| {
        diagnostics.captureBody(writer.buffered(), content_length, true);
        return err;
    };
}

fn bodyReadLimit(received: usize, capacity: usize, content_length: ?u64) usize {
    std.debug.assert(received < capacity);
    std.debug.assert(capacity <= codec.response_bytes_max);
    const available = capacity - received;
    const remaining = if (content_length) |declared| declared - received else available;
    return @intCast(@min(available, remaining));
}

fn finishBody(writer: *std.Io.Writer, total: u64, diagnostics: *FailureDiagnostics) usize {
    std.debug.assert(writer.end <= codec.response_bytes_max);
    std.debug.assert(total == writer.end);
    diagnostics.captureBody(writer.buffered(), total, false);
    return writer.end;
}

fn probeResponseEnd(io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer, diagnostics: *FailureDiagnostics) !usize {
    std.debug.assert(writer.end > 0);
    std.debug.assert(writer.end <= codec.response_bytes_max);
    // As above, cancellation is checked after every valid zero-byte decode.
    while (true) {
        var extra_storage: [1]u8 = undefined;
        var extra_writer = std.Io.Writer.fixed(&extra_storage);
        const count = reader.stream(&extra_writer, .limited(1)) catch |err| switch (err) {
            error.EndOfStream => return finishBody(writer, writer.end, diagnostics),
            error.ReadFailed => {
                diagnostics.captureBody(writer.buffered(), null, true);
                return error.ResponseReadFailed;
            },
            error.WriteFailed => unreachable,
        };
        if (count == 0) {
            try checkBodyCancellation(io, writer, null, diagnostics);
            continue;
        }
        diagnostics.captureBody(writer.buffered(), null, true);
        return error.ResponseTooLarge;
    }
}

fn classificationForStatus(status: u16) HttpClassification {
    std.debug.assert(status >= 100);
    std.debug.assert(status <= 999);
    if (status == 529) return .overloaded;
    if (status >= 500 and status <= 599) return .server_failure;
    return switch (status) {
        200 => .success,
        400 => .bad_request,
        401 => .authentication_failed,
        403 => .forbidden,
        404 => .not_found,
        422 => .invalid_request,
        429 => .rate_limited,
        else => .unexpected_status,
    };
}

fn captureHeaders(head: std.http.Client.Response.Head, diagnostics: *FailureDiagnostics) void {
    std.debug.assert(diagnostics.status != null);
    std.debug.assert(diagnostics.request_id.len == 0);
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-request-id")) diagnostics.request_id.set(header.value);
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) diagnostics.retry_after.set(header.value);
        if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining")) diagnostics.rate_limit_remaining.set(header.value);
        if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-reset")) diagnostics.rate_limit_reset.set(header.value);
    }
}

test "client classifies failures and retains bounded diagnostics" {
    const Fixture = struct {
        status: u16,
        fn post(pointer: *anyopaque, request: *const HttpRequest, response_buffer: []u8, diagnostics: *FailureDiagnostics) !HttpResponse {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            _ = request;
            _ = response_buffer;
            diagnostics.retry_after.set("17");
            return .{ .status = self.status, .body = "bounded failure detail" };
        }
    };
    const question = codec.Question{ .id = "root", .instructions = "Choose.", .option_ids = &.{"0"}, .option_descriptions = &.{"Stack"} };
    const request = codec.Request{ .model = "jev", .state_request = "x", .state_context = "y", .questions = &.{question} };
    var request_buffer: [1024]u8 = undefined;
    var response_buffer: [1024]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    var diagnostics = FailureDiagnostics{};
    var fixture = Fixture{ .status = 403 };
    const client = Client{ .transport = .{ .context = &fixture, .post_fn = Fixture.post } };
    try std.testing.expectError(error.Forbidden, client.evaluate("key", &request, &request_buffer, &response_buffer, &scratch, &diagnostics));
    try std.testing.expectEqual(@as(?u16, 403), diagnostics.status);
    try std.testing.expectEqual(HttpClassification.forbidden, diagnostics.classification);
    try std.testing.expectEqualStrings("bounded failure detail", diagnostics.bodySlice());
    try std.testing.expectEqualStrings("17", diagnostics.retry_after.slice());
    fixture.status = 503;
    try std.testing.expectError(error.ServerFailure, client.evaluate("key", &request, &request_buffer, &response_buffer, &scratch, &diagnostics));
    try std.testing.expectEqual(HttpClassification.server_failure, diagnostics.classification);
}

test "client preserves HTTP status and body diagnostics when body reading fails" {
    const Fixture = struct {
        fn post(pointer: *anyopaque, request: *const HttpRequest, response_buffer: []u8, diagnostics: *FailureDiagnostics) !HttpResponse {
            _ = pointer;
            _ = request;
            _ = response_buffer;
            diagnostics.status = 503;
            diagnostics.captureBody("partial body", 900, true);
            return error.ResponseTooLarge;
        }
    };
    var fixture: u8 = 0;
    var diagnostics = FailureDiagnostics{};
    var request_buffer: [1024]u8 = undefined;
    var response_buffer: [1024]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const question = codec.Question{ .id = "root", .instructions = "Choose.", .option_ids = &.{"0"}, .option_descriptions = &.{"Stack"} };
    const request = codec.Request{ .model = "jev", .state_request = "x", .state_context = "y", .questions = &.{question} };
    const client = Client{ .transport = .{ .context = &fixture, .post_fn = Fixture.post } };
    try std.testing.expectError(error.ResponseTooLarge, client.evaluate("key", &request, &request_buffer, &response_buffer, &scratch, &diagnostics));
    try std.testing.expectEqual(@as(?u16, 503), diagnostics.status);
    try std.testing.expectEqual(HttpClassification.server_failure, diagnostics.classification);
    try std.testing.expectEqual(@as(?u64, 900), diagnostics.body_bytes_total);
    try std.testing.expect(diagnostics.body_truncated);
}

test "StdHttpTransport emits required headers on the wire" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .kernel_backlog = 1, .reuse_address = true });
    defer server.deinit(io);
    var capture = WireCapture{};
    const thread = try std.Thread.spawn(.{}, captureWireRequest, .{ &server, io, &capture });
    var transport = StdHttpTransport{ .io = io, .allocator = std.testing.allocator };
    var url_storage: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_storage, "http://127.0.0.1:{d}/v1/systemone", .{server.socket.address.getPort()});
    var response_buffer: [1024]u8 = undefined;
    var diagnostics = FailureDiagnostics{};
    const response_result = transport.transport().post_fn(&transport, &.{
        .url = url,
        .authorization = "Bearer wire-test-key",
        .content_type = "application/json",
        .body = "{\"wire\":true}",
    }, &response_buffer, &diagnostics);
    thread.join();
    if (capture.failure) |failure| return failure;
    const response = try response_result;
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("POST /v1/systemone HTTP/1.1", capture.requestLine());
    try std.testing.expectEqualStrings("Bearer wire-test-key", capture.authorization.slice());
    try std.testing.expectEqualStrings("application/json", capture.content_type.slice());
    try std.testing.expectEqualStrings("identity", capture.accept_encoding.slice());
    try std.testing.expectEqualStrings("{\"wire\":true}", capture.bodySlice());
    try std.testing.expectEqualStrings("wire-request-7", diagnostics.request_id.slice());
    try std.testing.expectEqualStrings("5", diagnostics.retry_after.slice());
}

test "StdHttpTransport rejects premature EOF and preserves declared diagnostics" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .kernel_backlog = 1, .reuse_address = true });
    defer server.deinit(io);
    var capture = WireCapture{
        .request_body_expected_len = 2,
        .response = "HTTP/1.1 502 Upstream Error\r\ncontent-length: 12\r\nx-request-id: truncated-9\r\nconnection: close\r\n\r\npartial",
    };
    const thread = try std.Thread.spawn(.{}, captureWireRequest, .{ &server, io, &capture });
    var transport = StdHttpTransport{ .io = io, .allocator = std.testing.allocator };
    var url_storage: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_storage, "http://127.0.0.1:{d}/v1/systemone", .{server.socket.address.getPort()});
    var response_buffer: [1024]u8 = undefined;
    var diagnostics = FailureDiagnostics{};
    const result = transport.transport().post_fn(&transport, &.{ .url = url, .authorization = "Bearer test", .content_type = "application/json", .body = "{}" }, &response_buffer, &diagnostics);
    thread.join();
    if (capture.failure) |failure| return failure;
    try std.testing.expectError(error.ResponseTruncated, result);
    try std.testing.expectEqual(@as(?u16, 502), diagnostics.status);
    try std.testing.expectEqualStrings("partial", diagnostics.bodySlice());
    try std.testing.expectEqual(@as(?u64, 12), diagnostics.body_bytes_total);
    try std.testing.expect(diagnostics.body_truncated);
    try std.testing.expectEqualStrings("truncated-9", diagnostics.request_id.slice());
}

test "bounded reader preserves prefix on transport read failure" {
    var reader = std.Io.Reader.failing;
    reader.buffer = @constCast("prefix");
    reader.seek = 0;
    reader.end = "prefix".len;
    var output: [32]u8 = undefined;
    var diagnostics = FailureDiagnostics{ .status = 200 };
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectError(error.ResponseReadFailed, readResponseBody(io, &reader, &output, 10, &diagnostics));
    try std.testing.expectEqualStrings("prefix", diagnostics.bodySlice());
    try std.testing.expectEqual(@as(?u64, 10), diagnostics.body_bytes_total);
    try std.testing.expect(diagnostics.body_truncated);
}

test "bounded reader distinguishes oversized declared response" {
    var reader = std.Io.Reader.fixed("0123456789");
    var output: [6]u8 = undefined;
    var diagnostics = FailureDiagnostics{ .status = 200 };
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectError(error.ResponseTooLarge, readResponseBody(io, &reader, &output, 10, &diagnostics));
    try std.testing.expectEqualStrings("012345", diagnostics.bodySlice());
    try std.testing.expectEqual(@as(?u64, 10), diagnostics.body_bytes_total);
    try std.testing.expect(diagnostics.body_truncated);
}

test "fragmented TLS decode tolerates repeated zero reads before and after plaintext" {
    var decoded = FragmentedTlsDecodedReader.init("tls-body", 8, 3);
    var output: [16]u8 = undefined;
    var diagnostics = FailureDiagnostics{ .status = 200 };
    const io = std.Io.Threaded.global_single_threaded.io();
    const body_len = try readResponseBody(io, &decoded.interface, &output, null, &diagnostics);
    try std.testing.expectEqualStrings("tls-body", output[0..body_len]);
    try std.testing.expectEqual(@as(u8, 0), decoded.zeros_before);
    try std.testing.expectEqual(@as(u8, 0), decoded.zeros_after);
    try std.testing.expect(!diagnostics.body_truncated);
}

test "caller cancellation bounds an infinite decoded zero sequence" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var reader = InfiniteZeroReader.init();
    var output: [16]u8 = undefined;
    var diagnostics = FailureDiagnostics{ .status = 200 };
    var future = try io.concurrent(readResponseBody, .{ io, &reader.interface, &output, null, &diagnostics });
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(diagnostics.body_truncated);
}

const FragmentedTlsDecodedReader = struct {
    interface: std.Io.Reader,
    plaintext: []const u8,
    plaintext_offset: u8 = 0,
    zeros_before: u8,
    zeros_after: u8,

    fn init(plaintext: []const u8, zeros_before: u8, zeros_after: u8) FragmentedTlsDecodedReader {
        std.debug.assert(plaintext.len > 0);
        std.debug.assert(plaintext.len <= std.math.maxInt(u8));
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .plaintext = plaintext,
            .zeros_before = zeros_before,
            .zeros_after = zeros_after,
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FragmentedTlsDecodedReader = @alignCast(@fieldParentPtr("interface", reader));
        if (self.zeros_before > 0) {
            self.zeros_before -= 1;
            return 0;
        }
        if (self.plaintext_offset < self.plaintext.len) {
            const remaining = self.plaintext[self.plaintext_offset..];
            const count = try writer.write(limit.sliceConst(remaining));
            self.plaintext_offset += @intCast(count);
            return count;
        }
        if (self.zeros_after > 0) {
            self.zeros_after -= 1;
            return 0;
        }
        return error.EndOfStream;
    }
};

const InfiniteZeroReader = struct {
    interface: std.Io.Reader,

    fn init() InfiniteZeroReader {
        return .{ .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 } };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        std.debug.assert(@intFromPtr(reader) != 0);
        std.debug.assert(@intFromPtr(writer) != 0);
        _ = limit;
        return 0;
    }
};

test "chunked loopback body below capacity succeeds after zero progress" {
    var output: [5]u8 = undefined;
    var diagnostics = FailureDiagnostics{};
    const response = try runChunkedLoopback("3\r\nabc\r\n0\r\n\r\n", &output, &diagnostics);
    try std.testing.expectEqualStrings("abc", response.body);
    try std.testing.expectEqual(@as(?u64, 3), diagnostics.body_bytes_total);
    try std.testing.expect(!diagnostics.body_truncated);
}

test "chunked loopback body exactly at capacity succeeds after zero progress probe" {
    var output: [5]u8 = undefined;
    var diagnostics = FailureDiagnostics{};
    const response = try runChunkedLoopback("5\r\nabcde\r\n0\r\n\r\n", &output, &diagnostics);
    try std.testing.expectEqualStrings("abcde", response.body);
    try std.testing.expectEqual(@as(?u64, 5), diagnostics.body_bytes_total);
    try std.testing.expect(!diagnostics.body_truncated);
}

test "chunked loopback body over capacity returns bounded overflow" {
    var output: [5]u8 = undefined;
    var diagnostics = FailureDiagnostics{};
    try std.testing.expectError(error.ResponseTooLarge, runChunkedLoopback("6\r\nabcdef\r\n0\r\n\r\n", &output, &diagnostics));
    try std.testing.expectEqualStrings("abcde", diagnostics.bodySlice());
    try std.testing.expectEqual(@as(?u64, null), diagnostics.body_bytes_total);
    try std.testing.expect(diagnostics.body_truncated);
}

fn runChunkedLoopback(chunked_body: []const u8, response_buffer: []u8, diagnostics: *FailureDiagnostics) !HttpResponse {
    std.debug.assert(chunked_body.len > 0);
    std.debug.assert(response_buffer.len > 0);
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .kernel_backlog = 1, .reuse_address = true });
    defer server.deinit(io);
    var response_storage: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_storage, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n{s}", .{chunked_body});
    var capture = WireCapture{ .request_body_expected_len = 2, .response = response };
    const thread = try std.Thread.spawn(.{}, captureWireRequest, .{ &server, io, &capture });
    var transport = StdHttpTransport{ .io = io, .allocator = std.testing.allocator };
    var url_storage: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_storage, "http://127.0.0.1:{d}/v1/systemone", .{server.socket.address.getPort()});
    const result = transport.transport().post_fn(&transport, &.{ .url = url, .authorization = "Bearer test", .content_type = "application/json", .body = "{}" }, response_buffer, diagnostics);
    thread.join();
    if (capture.failure) |failure| return failure;
    return result;
}

const WireCapture = struct {
    request_line: [128]u8 = undefined,
    request_line_len: u8 = 0,
    authorization: BoundedHeader = .{},
    content_type: BoundedHeader = .{},
    accept_encoding: BoundedHeader = .{},
    body: [1024]u8 = undefined,
    body_len: u16 = 0,
    failure: ?anyerror = null,
    request_body_expected_len: u16 = "{\"wire\":true}".len,
    response: []const u8 = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nx-request-id: wire-request-7\r\nretry-after: 5\r\nconnection: close\r\n\r\n{}",

    fn requestLine(self: *const WireCapture) []const u8 {
        std.debug.assert(self.request_line_len <= self.request_line.len);
        std.debug.assert(self.request_line_len > 0);
        return self.request_line[0..self.request_line_len];
    }

    fn bodySlice(self: *const WireCapture) []const u8 {
        std.debug.assert(self.body_len <= self.body.len);
        std.debug.assert(self.body_len > 0);
        return self.body[0..self.body_len];
    }
};

fn captureWireRequest(server: *std.Io.net.Server, io: std.Io, capture: *WireCapture) void {
    std.debug.assert(@intFromPtr(server) != 0);
    std.debug.assert(@intFromPtr(capture) != 0);
    captureWireRequestFallible(server, io, capture) catch |err| {
        capture.failure = err;
    };
}

fn captureWireRequestFallible(server: *std.Io.net.Server, io: std.Io, capture: *WireCapture) !void {
    std.debug.assert(capture.request_line_len == 0);
    std.debug.assert(capture.body_len == 0);
    const stream = try server.accept(io);
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const request_line = std.mem.trimEnd(u8, (try reader.interface.takeDelimiter('\n')) orelse return error.MissingRequestLine, "\r");
    if (request_line.len > capture.request_line.len) return error.RequestLineTooLong;
    @memcpy(capture.request_line[0..request_line.len], request_line);
    capture.request_line_len = @intCast(request_line.len);
    try captureWireHeaders(&reader.interface, capture);
    const content_length = capture.request_body_expected_len;
    try reader.interface.readSliceAll(capture.body[0..content_length]);
    capture.body_len = @intCast(content_length);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(capture.response);
    try writer.interface.flush();
}

fn captureWireHeaders(reader: *std.Io.Reader, capture: *WireCapture) !void {
    std.debug.assert(capture.authorization.len == 0);
    std.debug.assert(capture.content_type.len == 0);
    while (true) {
        const line = std.mem.trimEnd(u8, (try reader.takeDelimiter('\n')) orelse return error.TruncatedHeaders, "\r");
        if (line.len == 0) break;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
        const name = line[0..separator];
        const value = std.mem.trim(u8, line[separator + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "authorization")) capture.authorization.set(value);
        if (std.ascii.eqlIgnoreCase(name, "content-type")) capture.content_type.set(value);
        if (std.ascii.eqlIgnoreCase(name, "accept-encoding")) capture.accept_encoding.set(value);
    }
}
