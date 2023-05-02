const std = @import("std");
const utils = @import("utils.zig");

// marker_mapping = {
//     0xffd8: "Start of Image",
//     0xffe0: "Application Default Header",
//     0xffdb: "Quantization Table",
//     0xffc0: "Start of Frame",
//     0xffc4: "Define Huffman Table",
//     0xffda: "Start of Scan",
//     0xffd9: "End of Image"
// }

const MarkerTuple = struct {
    marker: Marker,
    offset: u8,
};

const Parser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Self {
        return .{ .allocator = allocator, .data = data };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

const Marker = enum(u16) {
    startOfImage = 0xffd8,
    app0 = 0xffe0,
    quantizationTable = 0xffdb,
    startOfFrame0 = 0xffc0,
    defineHuffmanTable = 0xffc4,
    startOfScan = 0xffda,
    endOfImage = 0xffd9,
    defineRestartInterval = 0xffdd,
    _,
};

const HuffmanTableHeader = packed struct {
    class: Class,
    destinationIdentifier: u4,

    const Class = enum(u4) {
        DcOrLossless = 0x0,
        Ac = 0x1,
    };
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

    var restartInterval: ?u16 = null;

    while (i < buffer.len) : (i += 2) {
        const value = std.mem.readIntSlice(u16, buffer[i .. i + 2], std.builtin.Endian.Big);
        const marker = @intToEnum(Marker, value);

        if (soa_found and marker == .endOfImage) {}

        if (!soa_found or marker == .endOfImage) { // no SoS marker found, treat all data as tokens
            std.debug.print("{x} 0x{?} -> ", .{ i, std.fmt.fmtSliceHexLower(buffer[i .. i + 2]) });
            std.debug.print("{?}\n", .{marker});
        }

        if (!soa_found) {
            switch (marker) {
                .startOfImage => {},
                .endOfImage => {
                    break;
                },
                .defineRestartInterval => {
                    restartInterval = std.mem.readIntSlice(u16, buffer[i + 2 .. i + 4], std.builtin.Endian.Big); // skip two bytes to find the length we need to skip
                    i += 4; // NOTE: HACK
                },
                .startOfScan => { // found "Start Of Scan" marker, all following data is raw data, start brute-force search for end token
                    soa_found = true;
                },
                .defineHuffmanTable => {
                    i += 2;
                    const block_length = std.mem.readIntSlice(u16, buffer[i .. i + 2], std.builtin.Endian.Big);
                    const end_position = i + block_length;
                    i += 2;

                    while (true) {
                        const table_class = @ptrCast(*HuffmanTableHeader, &buffer[i]);
                        i += 1;
                        std.debug.print("HTH: {?}\n", .{table_class});

                        const lengths: *[16]u8 = @ptrCast(*[16]u8, buffer[i .. i + 16]);
                        i += 16;
                        std.debug.print("Lengths: ", .{});

                        utils.slicePrint(u8, lengths);
                        std.debug.print("\n", .{});

                        var sum: usize = 0;
                        for (lengths) |len| {
                            sum += len;
                        }
                        std.debug.print("Total element length: {d}\n", .{sum});

                        var data_i: usize = 0;
                        _ = data_i;
                        var code_candidate: u16 = 0;
                        _ = code_candidate;
                        var code_index: usize = 0;
                        _ = code_index;

                        i += sum;

                        if (i == end_position) break;

                        // var code_map = std.AutoHashMap(u5, u16).init(allocator);
                        // defer code_map.deinit();

                        // while (code_index < 16) : (code_index += 1) {
                        //     const code_count_for_index = lengths[code_index];
                        //     var current_code_index: usize = 0;
                        //     std.debug.print("{d} codes of length {d}: [", .{ code_count_for_index, code_index + 1 });
                        //     while (current_code_index < code_count_for_index) : (current_code_index += 1) {
                        //         std.debug.print("{b}", .{code_candidate});
                        //         if (current_code_index != code_count_for_index - 1) std.debug.print(",", .{});
                        //         code_candidate += 1;
                        //     }
                        //     std.debug.print("]\n", .{});

                        //     code_candidate <<= 1; // shift to the left to add zero in front
                        // }
                    }

                    i -= 2; // HACK: why this is needed?
                },
                else => {
                    const block_length = std.mem.readIntSlice(u16, buffer[i + 2 .. i + 4], std.builtin.Endian.Big); // skip two bytes to find the length we need to skip
                    // std.debug.print("block length: 0x{?} -> {d}\n", .{ std.fmt.fmtSliceHexLower(buffer[i + 2 .. i + 4]), block_length });
                    i += block_length;
                },
            }
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
