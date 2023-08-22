const std = @import("std");
const io = std.io;
const testing = std.testing;

pub fn SkippingReader(comptime ReaderType: type) type {
    return struct {
        inner_reader: ReaderType,

        pub const Error = ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            return self.inner_reader.read(dest);
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

test "SkippingReader identical" {
    const buffer: []const u8 = &[_]u8{
        0xAB,
        0xCD,
        0xFF,
        0x00,
    };

    var bStream = std.io.fixedBufferStream(buffer);

    var fbReader = bStream.reader();
    var fbBuffer: [2]u8 = undefined;
    _ = try fbReader.read(&fbBuffer);

    bStream = std.io.fixedBufferStream(buffer);
    fbReader = bStream.reader();
    var sr = SkippingReader(@TypeOf(fbReader)){ .inner_reader = fbReader };
    var srReader = sr.reader();
    var srBuffer: [2]u8 = undefined;
    _ = try srReader.read(&srBuffer);

    try testing.expectEqualSlices(u8, &fbBuffer, &srBuffer);
}
