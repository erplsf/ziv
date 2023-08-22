const std = @import("std");
const io = std.io;
const testing = std.testing;

// TODO: accept slice of bytes - "pattern", in which the last byte is skipped if the whole pattern is found
// TODO: use readByte?
// TODO: add tests to cover it

pub fn SkippingReader(comptime ReaderType: type, comptime len: usize) type {
    return struct {
        inner_reader: ReaderType,
        pattern: []const u8,

        pub const Error = ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        // pub fn init(inner_reader: ReaderType, pattern: []const u8) Self {
        //     return .{
        //         .inner_reader = inner_reader,
        //         .pattern = pattern,
        //     };
        // }

        pub fn read(self: *Self, dest: []u8) Error!usize {
            var buf: [len]u8 = undefined;
            _ = buf;
            // try self.inner_reader.read(&buf);
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

    const pattern: []const u8 = &[_]u8{
        0xFF,
        0x00,
    };

    var bStream = std.io.fixedBufferStream(buffer);

    var fbReader = bStream.reader();
    var fbBuffer: [2]u8 = undefined;
    _ = try fbReader.read(&fbBuffer);

    bStream = std.io.fixedBufferStream(buffer);
    fbReader = bStream.reader();
    var sr = SkippingReader(@TypeOf(fbReader), pattern.len){ .inner_reader = fbReader, .pattern = pattern };
    var srReader = sr.reader();
    var srBuffer: [2]u8 = undefined;
    _ = try srReader.read(&srBuffer);

    try testing.expectEqualSlices(u8, &fbBuffer, &srBuffer);
}
