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

pub fn mapPrint(
    comptime K: type,
    comptime V: type,
) void {
    _ = V;
    _ = K;
}
