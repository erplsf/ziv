const std = @import("std");

// marker_mapping = {
//     0xffd8: "Start of Image",
//     0xffe0: "Application Default Header",
//     0xffdb: "Quantization Table",
//     0xffc0: "Start of Frame",
//     0xffc4: "Define Huffman Table",
//     0xffda: "Start of Scan",
//     0xffd9: "End of Image"
// }

const Marker = enum(u16) {
    startOfImage = 0xffd8,
    app0 = 0xffe0,
    quantizationTable = 0xffdb,
    startOfFrame = 0xffc0,
    defineHuffmanTable = 0xffc4,
    startOfScan = 0xffda,
    endOfImage = 0xffd9,
    _,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.fs.realpath("res/cat.jpg", &path_buffer);

    std.debug.print("path: {s}\n", .{path});

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const file_size = (try file.metadata()).size();
    var buffer = try allocator.alloc(u8, file_size);

    try file.reader().readNoEof(buffer);
    var i: usize = 0;
    var soa_found = false;
    while (i < buffer.len) {
        const value = std.mem.readIntSlice(u16, buffer[i .. i + 2], std.builtin.Endian.Big);
        const marker = @intToEnum(Marker, value);

        if (!soa_found or marker == .endOfImage) { // no SoS marker found, treat all data as tokens
            std.debug.print("{d} 0x{?} -> ", .{ i, std.fmt.fmtSliceHexLower(buffer[i .. i + 2]) });
            std.debug.print("{?}\n", .{marker});
        }

        if (soa_found) {
            i += 2;
        } else switch (marker) {
            .startOfImage => {
                i += 2;
            },
            .endOfImage => {
                break;
            },
            .startOfScan => { // found "Start Of Scan" marker, all following data is raw data, start brute-force search for end token
                soa_found = true;
                i += 2;
            },
            else => {
                i += 2;
                const block_length = std.mem.readIntSlice(u16, buffer[i .. i + 2], std.builtin.Endian.Big);
                i += block_length;
            },
        }
    }

    // while (true) {
    //     const number_of_read_bytes = try buffered_file.read(&buffer);

    //     std.debug.print("0x{d}", .{std.fmt.fmtSliceHexLower(&buffer)});

    //     if (number_of_read_bytes == 2) {
    //         break; // No more data
    //     }
    //     // Buffer now has some of the file bytes, do something with it here...
    // }
}
