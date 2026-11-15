const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;

// Bound the server's wait for input, not delivery of a consuming READ reply.
// A caller/transport timeout after consumption would lose a command forever.
pub fn read(app: anytype, handle: u32, out: []u8, wait_ticks: u64) i32 {
    if (out.len == 0) return 0;
    const capacity = @min(out.len, abi.net_service_tcp_read_max);
    var body: [6]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], handle, .little);
    std.mem.writeInt(u16, body[4..6], @intCast(capacity), .little);
    var message: [6 + r4os.service_deadline.footer_size]u8 = undefined;
    const deadline = if (wait_ticks == 0) r4os.service_deadline.tcp_poll_tick else @min(app.sys.ticks() +| wait_ticks, std.math.maxInt(u64) - 1);
    const payload = r4os.service_deadline.append(&message, &body, deadline).?;
    var request: r4os.r4net.NetSocketRequest = .{};
    if (app.net.netSocketBegin(.tcp, abi.net_service_op_tcp_read_result, payload, abi.io_wait_forever, &request) != abi.io_ok) return -1;
    // The request owns async buffers. In particular, BUSY close does not end
    // their lifetime; retain this frame until the exact request is released.
    defer {
        while (request.active and request.request_id != 0) {
            const closed = app.net.netSocketClose(&request);
            if (closed == abi.io_ok or closed == abi.io_error_not_found) break;
            _ = app.net.netSocketWait(&request, abi.io_wait_forever);
            app.sys.sleepTicks(1);
        }
    }
    while (true) {
        const rc = app.net.netSocketWait(&request, abi.io_wait_forever);
        if (rc == abi.io_error_busy) {
            app.sys.sleepTicks(1);
            continue;
        }
        if (rc != abi.io_ok or !request.completed() or request.info.result < @sizeOf(abi.NetServiceTcpResult) or request.header.status != abi.service_api_result_ok) return -1;
        break;
    }
    var result: abi.NetServiceTcpResult = .{};
    if (!request.tcpResult(&result) or result.result != abi.tcp_result_ok) return -1;
    const data = request.tcpData(&result) orelse return -1;
    if (data.len > capacity or result.bytes != data.len) return -1;
    if (data.len != 0) {
        @memcpy(out[0..data.len], data);
        return @intCast(data.len);
    }
    // An operation timeout leaves the connection open; EOF/reset does not.
    return if (r4os.r4net.tcpResultReadiness(&result).terminal and result.lifecycle_cause != abi.net_service_socket_lifecycle_timeout) -1 else 0;
}

test "control READ keeps consumed replies past operation deadline and drains BUSY close" {
    const Fake = struct {
        tick: u64 = 100,
        begins: usize = 0,
        waits: usize = 0,
        closes: usize = 0,
        timeout_reply: bool = false,
        oversized_reply: bool = false,
        fn ticks(self: *@This()) u64 {
            return self.tick;
        }
        fn sleepTicks(self: *@This(), _: u64) void {
            self.tick += 1;
        }
        fn netSocketBegin(self: *@This(), service: r4os.r4net.NetSocketService, op: u16, payload: []const u8, timeout: u64, request: *r4os.r4net.NetSocketRequest) i32 {
            std.debug.assert(service == .tcp and op == abi.net_service_op_tcp_read_result and timeout == abi.io_wait_forever);
            const decoded = r4os.service_deadline.split(payload);
            std.debug.assert(decoded.deadline_tick.? == 125 and decoded.payload.len == 6);
            std.debug.assert(std.mem.readInt(u32, decoded.payload[0..4], .little) == 42 and std.mem.readInt(u16, decoded.payload[4..6], .little) == 4);
            self.begins += 1;
            request.* = .{ .active = true, .request_id = 7 };
            return abi.io_ok;
        }
        fn netSocketWait(self: *@This(), request: *r4os.r4net.NetSocketRequest, timeout: u64) i32 {
            std.debug.assert(timeout == abi.io_wait_forever and request.active);
            self.waits += 1;
            self.tick = 200; // delivery after the server's finite input budget
            var result: abi.NetServiceTcpResult = .{};
            result.result = abi.tcp_result_ok;
            if (self.timeout_reply) {
                result.lifecycle_cause = abi.net_service_socket_lifecycle_timeout;
                result.flags = abi.net_service_tcp_flag_timeout;
            } else {
                result.bytes = if (self.oversized_reply) 5 else 3;
                result.flags = abi.net_service_tcp_flag_data;
            }
            @memcpy(request.response[0..@sizeOf(abi.NetServiceTcpResult)], std.mem.asBytes(&result));
            @memcpy(request.response[@sizeOf(abi.NetServiceTcpResult)..][0..5], "abcde");
            request.response_len = @sizeOf(abi.NetServiceTcpResult) + result.bytes;
            request.info.state = abi.io_state_completed;
            request.info.result = @intCast(request.response_len);
            request.header.status = abi.service_api_result_ok;
            return abi.io_ok;
        }
        fn netSocketClose(self: *@This(), request: *r4os.r4net.NetSocketRequest) i32 {
            self.closes += 1;
            if (self.closes == 1) return abi.io_error_busy;
            request.reset();
            return abi.io_ok;
        }
    };
    var fake: Fake = .{};
    const app = .{ .sys = &fake, .net = &fake };
    var out: [4]u8 = @splat(0xcc);
    try std.testing.expectEqual(@as(i32, 3), read(app, 42, &out, 25));
    try std.testing.expectEqualSlices(u8, "abc", out[0..3]);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    try std.testing.expectEqual(@as(usize, 2), fake.closes);
    try std.testing.expectEqual(@as(usize, 2), fake.waits);
    fake = .{ .timeout_reply = true };
    try std.testing.expectEqual(@as(i32, 0), read(app, 42, &out, 25));
    fake = .{ .oversized_reply = true };
    out = @splat(0xcc);
    try std.testing.expectEqual(@as(i32, -1), read(app, 42, &out, 25));
    try std.testing.expectEqualSlices(u8, &(@as([4]u8, @splat(0xcc))), &out);
    try std.testing.expectEqual(@as(usize, 2), fake.closes);
}
