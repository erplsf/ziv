const std = @import("std");
const utils = @import("utils.zig");

const Marker = enum(u16) {
    startOfImage = 0xffd8,
    app0 = 0xffe0,
    app1 = 0xffe1,
    app2 = 0xffe2,
    app13 = 0xffed,
    app14 = 0xffee,
    quantizationTable = 0xffdb,
    startOfFrame0 = 0xffc0, // TODO: replace withc explicit check for sof0 frame as only supported after whole search
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

const QuantizationTableHeader = packed struct {
    class: Class,
    destinationIdentifier: u4,

    const Class = enum(u4) {
        DcOrLossless = 0x0,
        Ac = 0x1,
    };
};

const ComponentInformation = struct {
    id: u8, // component identifier (1 = Y, 2 = Cb, 3 = Cr) according to JFIF standard
}

const Parser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize = 0,

    markers: std.AutoHashMap(Marker, usize),

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Self {
        const markers = std.AutoHashMap(Marker, usize).init(allocator);
        return .{ .allocator = allocator, .data = data, .markers = markers };
    }

    pub fn deinit(self: *Self) void {
        self.markers.deinit();
    }

    pub fn decode(self: *Self) !void {
        try self.parseMarkers();
        try self.decodeSoF();
    }

    pub fn parseMarkers(self: *Self) !void {
        var i: usize = 0;
        var sos_found = false;

        var restartInterval: ?u16 = null;
        _ = restartInterval;

        while (i < self.data.len) : (i += 2) {
            const value = std.mem.readIntSlice(u16, self.data[i .. i + 2], std.builtin.Endian.Big);
            const marker = @intToEnum(Marker, value);

            if (!sos_found or marker == .endOfImage) { // no SoS marker found, treat all data as tokens
                std.debug.print("{x} 0x{?} -> ", .{ i, std.fmt.fmtSliceHexLower(self.data[i .. i + 2]) });
                std.debug.print("{?}\n", .{marker});
            }

            if (!sos_found) {
                try self.markers.put(marker, i);
                switch (marker) {
                    .startOfImage => {},
                    .endOfImage => {
                        break;
                    },
                    .defineRestartInterval => {
                        // restartInterval = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], std.builtin.Endian.Big); // skip two bytes to find the length we need to skip
                        i += 4; // NOTE: HACK
                    },
                    .startOfScan => { // found "Start Of Scan" marker, all following data is raw data, start brute-force search for end token
                        sos_found = true;
                    },
                    // .defineHuffmanTable => {
                    //     i += 2;
                    //     const block_length = std.mem.readIntSlice(u16, self.data[i .. i + 2], std.builtin.Endian.Big);
                    //     const end_position = i + block_length;
                    //     i += 2;

                    //     while (true) {
                    //         const table_class = @ptrCast(*const HuffmanTableHeader, &self.data[i]);
                    //         _ = table_class;
                    //         i += 1;
                    //         // std.debug.print("HTH: {?}\n", .{table_class});

                    //         const lengths: *const [16]u8 = @ptrCast(*const [16]u8, self.data[i .. i + 16]);
                    //         i += 16;
                    //         // std.debug.print("Lengths: ", .{});

                    //         // utils.slicePrint(u8, lengths);
                    //         // std.debug.print("\n", .{});

                    //         var sum: usize = 0;
                    //         for (lengths) |len| {
                    //             sum += len;
                    //         }
                    //         // std.debug.print("Total element count: {d}\n", .{sum});

                    //         var data_i: usize = 0;
                    //         _ = data_i;
                    //         var code_candidate: u16 = 0;
                    //         var code_index: usize = 0;

                    //         var code_map = std.AutoHashMap(u8, u16).init(self.allocator);
                    //         defer code_map.deinit();

                    //         while (code_index < 16) : (code_index += 1) {
                    //             const code_count_for_index = lengths[code_index];
                    //             var current_code_index: usize = 0;
                    //             // std.debug.print("{d} codes of length {d}: [", .{ code_count_for_index, code_index + 1 });
                    //             while (current_code_index < code_count_for_index) : (current_code_index += 1) {
                    //                 // std.debug.print("{b}", .{code_candidate});
                    //                 // if (current_code_index != code_count_for_index - 1) std.debug.print(",", .{});

                    //                 try code_map.put(self.data[i], code_candidate);
                    //                 i += 1;
                    //                 code_candidate += 1;
                    //             }
                    //             // std.debug.print("]\n", .{});

                    //             code_candidate <<= 1; // shift to the left to add zero in front
                    //         }

                    //         // var it = code_map.iterator();
                    //         // while (it.next()) |kv| {
                    //         //     std.debug.print("{b}: {b}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
                    //         // }

                    //         if (i == end_position) break;
                    //     }

                    //     // i += sum;

                    //     i -= 2; // HACK: why this is needed?
                    // },
                    // .quantizationTable => {
                    //     i += 2; // skip qunatization table marker
                    //     const block_length = std.mem.readIntSlice(u16, self.data[i .. i + 2], std.builtin.Endian.Big); // skip two bytes to find the length we need to skip
                    //     const end_position = (i - 2) + block_length;

                    //     i += 2;

                    //     while (true) {
                    //         const table_class = @ptrCast(*const QuantizationTableHeader, &self.data[i]);
                    //         i += 1;

                    //         i += 64;
                    //         std.debug.print("HTH: {?}\n", .{table_class});

                    //         if (i == end_position) break;
                    //     }

                    //     i += (block_length - 2); // substract two because header is included in block length
                    // },
                    else => {
                        const block_length = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], std.builtin.Endian.Big); // skip two bytes to find the length we need to skip
                        // std.debug.print("block length: 0x{?} -> {d}\n", .{ std.fmt.fmtSliceHexLower(self.data[i + 2 .. i + 4]), block_length });
                        i += block_length;
                    },
                }
            }
        }
    }

    fn decodeSoF(self: *Self) !void { // NOTE: we only support SOF0
        var i = self.markers.get(Marker.startOfFrame0).?;
        i += 4; // skip marker and block length

        const precision = self.data[i];
        std.debug.print("precision: {d}\n", .{precision});
        i += 1;
        const lineCount = std.mem.readIntSlice(u16, self.data[i .. i + 2], std.builtin.Endian.Big);
        std.debug.print("lineCount: {d}\n", .{lineCount});
        i += 2;
        const columnCount = std.mem.readIntSlice(u16, self.data[i .. i + 2], std.builtin.Endian.Big);
        std.debug.print("columnCount: {d}\n", .{columnCount});
        i += 2;
        const imageComponentCount = self.data[i];
        std.debug.print("imageComponentCount: {d}\n\n", .{imageComponentCount});
        i += 1;

        for (0..imageComponentCount) |currentComponentIndex| {
            std.debug.print("component {d}, value {d}\n", .{ currentComponentIndex, self.data[i] });
            i += 1;

            var stream = std.io.fixedBufferStream(self.data[i..]);
            var reader = std.io.bitReader(.Big, stream.reader());
            var out_bits: usize = undefined;
            const horizontalSampling = try reader.readBits(u4, 4, &out_bits);
            std.debug.print("horizontalSampling: {d}\n", .{horizontalSampling});
            const verticalSampling = try reader.readBits(u4, 4, &out_bits);
            std.debug.print("verticalSampling: {d}\n", .{verticalSampling});
            i += 1;
            const qTableDestination = self.data[i];
            std.debug.print("qTableDestination: {d}\n\n", .{qTableDestination});
            i += 1;
        }
    }

    pub fn buildHuffmanTables(self: *Self) !void {
        const dhtPosition = self.markers.get(Marker.defineHuffmanTable) orelse return ParserError.NoDefineHuffmanTableMarkerFound;
        _ = dhtPosition;
    }

    const ParserError = error{
        NoDefineHuffmanTableMarkerFound,
        ProgressiveDCTUnsupported,
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

    var parser: Parser = Parser.init(allocator, buffer);
    defer parser.deinit();

    try parser.decode();

    // var it = parser.markers.keyIterator();
    // while (it.next()) |key| {
    //     std.debug.print("{?}, ", .{key});
    // }
}
