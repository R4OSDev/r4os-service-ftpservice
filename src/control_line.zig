//! Bounded consuming FTP control stream. An overflow discards the whole
//! record through LF; a suffix can never become a second command.
const std = @import("std");
pub const Event = enum { more, ready, rejected };
pub fn push(buffer: []u8, len: *usize, discarding: *bool, byte: u8) Event {
    if (byte == '\n') {
        if (discarding.*) {
            discarding.* = false;
            len.* = 0;
            return .rejected;
        }
        if (len.* > 0 and buffer[len.* - 1] == '\r') len.* -= 1;
        return .ready;
    }
    if (discarding.*) return .more;
    if (len.* >= buffer.len) {
        len.* = 0;
        discarding.* = true;
        return .more;
    }
    buffer[len.*] = byte;
    len.* += 1;
    return .more;
}
test "split control records retain every UTF8 and whitespace byte" {
    const input = "STOR  ä🙂.bin \r\n";
    for (0..input.len + 1) |split| {
        var buffer: [64]u8 = undefined;
        var len: usize = 0;
        var discarding = false;
        var ready: usize = 0;
        for ([_][]const u8{ input[0..split], input[split..] }) |part| {
            for (part) |byte| switch (push(&buffer, &len, &discarding, byte)) {
                .more => {},
                .rejected => return error.UnexpectedRejection,
                .ready => {
                    try std.testing.expectEqualStrings(input[0 .. input.len - 2], buffer[0..len]);
                    ready += 1;
                    len = 0;
                },
            };
        }
        try std.testing.expectEqual(@as(usize, 1), ready);
        try std.testing.expect(!discarding and len == 0);
    }
}
test "overflow discards a destructive tail until newline and then recovers" {
    var buffer: [8]u8 = undefined;
    var len: usize = 0;
    var discarding = false;
    var rejected: usize = 0;
    var ready: usize = 0;
    for ("123456789DELE victim\r\nNOOP\r\n") |byte| switch (push(&buffer, &len, &discarding, byte)) {
        .more => {},
        .rejected => rejected += 1,
        .ready => {
            try std.testing.expectEqualStrings("NOOP", buffer[0..len]);
            ready += 1;
            len = 0;
        },
    };
    try std.testing.expectEqual(@as(usize, 1), rejected);
    try std.testing.expectEqual(@as(usize, 1), ready);
    for ("12345678\n") |byte| {
        const event = push(&buffer, &len, &discarding, byte);
        if (byte == '\n') try std.testing.expectEqual(Event.ready, event);
    }
    try std.testing.expectEqual(@as(usize, 8), len);
}
