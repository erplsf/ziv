const std = @import("std");
const io = std.io;
const testing = std.testing;

// TODO: accept slice of bytes - "pattern", in which the last byte is skipped if the whole pattern is found
// TODO: use readByte?
// TODO: add tests to cover it

pub fn SkippingReader(comptime ReaderType: type, comptime pattern: []const u8, comptime skip_bytes: usize) type {
    return struct {
        inner_reader: ReaderType,

        pattern_offset: usize = 0,

        pub const Error = ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            // NOTE: new code, read byte-by-byte and check pattern step-by-step
            var bytesRead: usize = 0;
            while (bytesRead < dest.len) {
                const byte = self.inner_reader.readByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };
                dest[bytesRead] = byte;
                bytesRead += 1;
                if (byte == pattern[self.pattern_offset]) {
                    self.pattern_offset += 1;
                    if (self.pattern_offset == pattern.len) {
                        bytesRead -= skip_bytes;
                    }
                    self.pattern_offset %= pattern.len;
                } else {
                    self.pattern_offset = 0;
                }
            }
            return bytesRead;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

test "identical with skip_bytes 0" {
    const buffer: []const u8 = &[_]u8{
        0xFF,
        0x00,
        0xAB,
        0xCD,
    };

    const pattern: []const u8 = &[_]u8{
        0xFF,
        0x00,
    };

    var bStream = std.io.fixedBufferStream(buffer);

    var fbReader = bStream.reader();
    var fbBuffer: [buffer.len]u8 = undefined;
    _ = try fbReader.read(&fbBuffer);

    bStream = std.io.fixedBufferStream(buffer);
    fbReader = bStream.reader();
    var sr = SkippingReader(@TypeOf(fbReader), pattern, 0){ .inner_reader = fbReader };
    var srReader = sr.reader();
    var srBuffer: [buffer.len]u8 = undefined;
    _ = try srReader.read(&srBuffer);

    try testing.expectEqualSlices(u8, &fbBuffer, &srBuffer);
}

test "works as expected with skip_bytes 1" {
    const buffer: []const u8 = &[_]u8{
        0xFF,
        0x00,
        0xAB,
        0xCD,
        0xFF,
        0xFF,
        0xAB,
        0x00,
        0x00,
        0xFF,
        0x00,
    };

    const pattern: []const u8 = &[_]u8{
        0xFF,
        0x00,
    };

    const wantedResult: []const u8 = &[_]u8{
        0xFF,
        0xAB,
        0xCD,
        0xFF,
        0xFF,
        0xAB,
        0x00,
        0x00,
        0xFF,
    };

    var bStream = std.io.fixedBufferStream(buffer);

    var fbReader = bStream.reader();
    var fbBuffer: [buffer.len]u8 = undefined;
    _ = try fbReader.read(&fbBuffer);

    bStream = std.io.fixedBufferStream(buffer);
    fbReader = bStream.reader();
    var skippingSr = SkippingReader(@TypeOf(fbReader), pattern, 1){ .inner_reader = fbReader };
    var skippingSrReader = skippingSr.reader();
    var smallSrBuffer: [wantedResult.len]u8 = undefined;
    _ = try skippingSrReader.read(&smallSrBuffer);

    try testing.expectEqualSlices(u8, wantedResult, &smallSrBuffer);
}
