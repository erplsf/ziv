const std = @import("std");

const Header = packed struct { // NOTE: real order is b:a, NOT a:b (LSB) (reverse)
    a: u4,
    b: u4,
};

pub fn main() !void {
    const buffer: []const u8 = &[_]u8{
        0b00000001,
        0b00010000,
    };
    for (0..2) |i| {
        const header: Header = @as(Header, @bitCast(buffer[i]));
        std.debug.print("{?}\n", .{header});
    }
}
