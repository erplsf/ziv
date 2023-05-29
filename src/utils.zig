const std = @import("std");

pub fn slicePrint(comptime T: type, slice: []const T) void {
    std.debug.print("[", .{});
    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        std.debug.print("{?}", .{slice[i]});
        if (i != slice.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("]", .{});
}

pub fn PrefixPrinter(comptime prefix: []const u8) type {
    return struct {
        const Self = @This();

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) void {
            _ = self;
            std.debug.print(prefix ++ fmt, args);
        }
    };
}
