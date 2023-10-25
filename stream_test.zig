const std = @import("std");

pub fn main() !void {
    const buffer: []const u8 = &[_]u8{
        0b11010000,
        0b10111111,
    };
    std.debug.print("{?}\n", .{std.fmt.fmtSliceHexLower(buffer)});
    var fbStream = std.io.fixedBufferStream(buffer);
    var reader = fbStream.reader();
    var bitReader = std.io.bitReader(std.builtin.Endian.Big, reader);
    var bitsRead = try bitReader.readBitsNoEof(u8, 2);
    std.debug.print("{b}\n", .{bitsRead});
    bitsRead = try bitReader.readBitsNoEof(u8, 2);
    std.debug.print("{b}\n", .{bitsRead});
    bitReader.alignToByte();
    bitsRead = try bitReader.readBitsNoEof(u8, 2);
    std.debug.print("{b}\n", .{bitsRead});
}
