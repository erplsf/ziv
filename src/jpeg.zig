const std = @import("std");
const utils = @import("utils.zig");

const JpegEndianness = std.builtin.Endian.Big;
const dPrint = std.debug.print;
const readInt = std.mem.readIntBig;
const readIntSlice = std.mem.readIntSliceBig;
const BLOCK_SIZE = 64;

const ValueType = enum(u1) {
    Dc = 0,
    Ac = 1,
};

const Marker = enum(u16) {
    startOfImage = 0xffd8,
    app0 = 0xffe0,
    app1 = 0xffe1,
    app2 = 0xffe2,
    app13 = 0xffed,
    app14 = 0xffee,
    quantizationTable = 0xffdb,
    startOfFrame0 = 0xffc0,
    defineHuffmanTable = 0xffc4,
    startOfScan = 0xffda,
    endOfImage = 0xffd9,
    defineRestartInterval = 0xffdd,
    _,
};

const Block = struct {
    components: [3][BLOCK_SIZE]i8,
};

const HuffmanTableHeader = packed struct {
    // HACK: wtf, order reversed, because of big-endian
    destinationIdentifier: u4,
    class: Class,

    const Class = enum(u4) {
        DcOrLossless = 0x0,
        Ac = 0x1,
    };
};

const QuantizationTableHeader = packed struct {
    const Self = @This();

    // HACK: wtf, order reversed, because of big-endian
    destinationIdentifier: u4,
    precision: Precision,

    const Precision = enum(u4) {
        @"8bit" = 0x0,
        @"16bit" = 0x1,
    };
};

const QuantizationTable = struct {
    header: QuantizationTableHeader,
    table: @Vector(64, u8), // NOTE: it's always u8 for Sequential DCT
};

const ComponentInformation = packed struct {
    id: u8, // NOTE: component identifier (1 = Y, 2 = Cb, 3 = Cr) according to JFIF standard
    horizontalSamples: u4,
    verticalSamples: u4,
    qTableDestination: u8,
};

const ComponentDestinationSelectors = packed struct {
    dcDestinationSelector: u4,
    acDestinationSelector: u4,
};

const HTKey = struct {
    length: u4, // NOTE: actual length - 1, so length 4 is coded as 3 here
    code: u16,
};

const HuffmanTable = std.AutoHashMap(HTKey, u8); // pairing between length and code to value

const Parser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    list: std.ArrayList(u8),
    data: []u8,
    imageDataPos: usize = undefined,

    markers: std.AutoHashMap(Marker, usize),
    componentTables: [3]ComponentInformation = undefined, // HACK: hardcoded numbers for JFIF Y/Cb/Cr
    huffmanTables: [2][2]HuffmanTable = undefined, // HACK: hardcoded numbers for baseline sequential DCT
    quantizationTables: [2]QuantizationTable = undefined,
    componentCount: usize = undefined,
    destinationSelectors: [3]ComponentDestinationSelectors = undefined,

    pWidth: usize = undefined,
    pHeight: usize = undefined,

    pub fn init(allocator: std.mem.Allocator, data: []u8) Self {
        const markers = std.AutoHashMap(Marker, usize).init(allocator);
        const list = std.ArrayList(u8).fromOwnedSlice(allocator, data);
        return .{ .allocator = allocator, .list = list, .data = list.items, .markers = markers };
    }

    pub fn deinit(self: *Self) void {
        self.markers.deinit();
        for (0..2) |dcAc| {
            for (0..2) |destination| {
                self.huffmanTables[dcAc][destination].deinit();
            }
        }
        self.list.deinit();
    }

    pub fn decode(self: *Self) !void {
        try self.parseMarkers();
        try self.decodeSoF();
        try self.buildHuffmanTables();
        try self.decodeQuantizationTables();
        try self.decodeStarOfScan();
        try self.cleanByteStuffing();
        try self.decodeImageData();
    }

    pub fn parseMarkers(self: *Self) !void {
        var i: usize = 0;
        var sos_found = false;

        var restartInterval: ?u16 = null;
        _ = restartInterval;

        while (i < self.data.len) : (i += 2) {
            const value = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
            const marker = @intToEnum(Marker, value);

            if (!sos_found or marker == .endOfImage) { // no SoS marker found, treat all data as tokens
                dPrint("{x} 0x{?} -> ", .{ i, std.fmt.fmtSliceHexLower(self.data[i .. i + 2]) });
                dPrint("{?}\n", .{marker});
            }

            if (!sos_found) {
                try self.markers.put(marker, i);
                switch (marker) {
                    .startOfImage => {},
                    .endOfImage => {
                        break;
                    },
                    .defineRestartInterval => {
                        // restartInterval = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], JpegEndianness); // skip two bytes to find the length we need to skip
                        i += 4; // NOTE: HACK
                    },
                    .startOfScan => { // found "Start Of Scan" marker, all following data is raw data, start brute-force search for end token
                        sos_found = true;
                    },
                    else => {
                        const block_length = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], JpegEndianness); // skip two bytes to find the length we need to skip
                        // dPrint("block length: 0x{?} -> {d}\n", .{ std.fmt.fmtSliceHexLower(self.data[i + 2 .. i + 4]), block_length });
                        i += block_length;
                    },
                }
            }
        }
    }

    // NOTE: we only support SOF0
    fn decodeSoF(self: *Self) !void {
        var i = self.markers.get(Marker.startOfFrame0) orelse return ParserError.NoRequiredMarkerFound;
        i += 4; // skip marker and block length

        const precision = self.data[i];
        dPrint("precision: {d}\n", .{precision});
        i += 1;
        const lineCount = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
        dPrint("lineCount: {d}\n", .{lineCount});
        self.pHeight = lineCount;
        i += 2;
        const columnCount = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
        dPrint("columnCount: {d}\n", .{columnCount});
        self.pWidth = lineCount;
        i += 2;
        const imageComponentCount = self.data[i];
        dPrint("imageComponentCount: {d}\n\n", .{imageComponentCount});
        i += 1;

        const packedComponentSize = 3;

        var destinationIdentifierSet = std.AutoHashMap(u8, void).init(self.allocator);
        defer destinationIdentifierSet.deinit();

        for (0..imageComponentCount) |index| {
            const offset = index * packedComponentSize;
            @memcpy(@ptrCast([*]u8, self.componentTables[index..].ptr), self.data[i + offset .. i + offset + packedComponentSize]); // HACK: unsafe but works :)
            try destinationIdentifierSet.put(self.componentTables[index].qTableDestination, {});
            dPrint("table: {?}\n", .{self.componentTables[index]});
        }

        dPrint("total unique qTables: {d}\n", .{destinationIdentifierSet.count()});
    }

    fn buildHuffmanTables(self: *Self) !void {
        var startIndex = self.markers.get(Marker.defineHuffmanTable) orelse return ParserError.NoRequiredMarkerFound;
        var i = startIndex;
        i += 2; // skip marker
        const full_block_length = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
        i += 2;

        const endIndex = startIndex + full_block_length;

        while (i < endIndex) {
            const tableClass = @ptrCast(*const HuffmanTableHeader, &self.data[i]);
            dPrint("HTH: {?}\n", .{tableClass});
            i += 1;

            const lengths = @ptrCast(*const [16]u8, self.data[i .. i + 16]);
            i += 16;

            dPrint("lengths: ", .{});
            utils.slicePrint(u8, lengths);
            dPrint("\n", .{});

            var code_map = HuffmanTable.init(self.allocator);
            var code_candidate: u16 = 0;
            var code_index: u4 = 0;

            while (true) {
                const code_count_for_index = lengths[code_index];
                var current_code_index: usize = 0;
                while (current_code_index < code_count_for_index) : (current_code_index += 1) {
                    const value = readInt(u8, &self.data[i]);
                    try code_map.put(.{ .length = code_index, .code = code_candidate }, value);
                    i += 1;
                    code_candidate += 1;
                }
                code_candidate <<= 1; // shift to the left (with zero in front);
                if (code_index != 15) code_index += 1 else break;
            }

            var kvIt = code_map.iterator();
            _ = kvIt;
            // while (kvIt.next()) |kv| {
            //     dPrint("kv: {?} -> {b}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
            // }

            self.huffmanTables[tableClass.destinationIdentifier][@enumToInt(tableClass.class)] = code_map;
        }
    }

    fn decodeQuantizationTables(self: *Self) !void {
        var startIndex = self.markers.get(Marker.quantizationTable) orelse return ParserError.NoRequiredMarkerFound;
        var i = startIndex;
        i += 2; // skip marker
        const full_block_length = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
        i += 2;

        const endIndex = (startIndex + 2) + full_block_length;

        var qIndex: usize = 0;
        while (i < endIndex) : (qIndex += 1) {
            const tableHeader = @bitCast(QuantizationTableHeader, self.data[i]);
            i += 1;

            const elements = @ptrCast(*const [64]u8, self.data[i .. i + 64]);
            var table: @Vector(64, u8) = elements.*;

            self.quantizationTables[qIndex].header = tableHeader;
            self.quantizationTables[qIndex].table = table;

            dPrint("{?}\n", .{self.quantizationTables[qIndex]});

            i += 64;
        }
    }

    fn decodeStarOfScan(self: *Self) !void {
        const startIndex = self.markers.get(Marker.startOfScan) orelse return ParserError.NoRequiredMarkerFound;
        var i: usize = startIndex;
        i += 2;

        const blockLength = readIntSlice(u16, self.data[i .. i + 2]);
        const endIndex = i + blockLength;
        i += 2;

        const componentCount = readInt(u8, &self.data[i]);
        dPrint("componentCount: {d}\n", .{componentCount});
        self.componentCount = componentCount;
        i += 1;

        for (0..componentCount) |componentIndex| {
            const id = readInt(u8, &self.data[i]);
            i += 1;
            const destinationSelectors = @bitCast(ComponentDestinationSelectors, readInt(u8, &self.data[i]));
            dPrint("cih: {?}, {?}\n", .{ id, destinationSelectors });

            self.destinationSelectors[componentIndex] = destinationSelectors;

            i += 1;
        }

        const ss = readInt(u8, &self.data[i]); // start of spectral selector, for Seq DCT == 0
        std.debug.assert(ss == 0);
        i += 1;

        const se = readInt(u8, &self.data[i]); // end of spectral selector, for Seq DCT == 63
        std.debug.assert(se == 63);
        i += 1;

        const ap = readInt(u8, &self.data[i]); // approximation bits, for Seq DCT == 0
        std.debug.assert(ap == 0);
        i += 1;

        std.debug.assert(i == endIndex); // assert we parsed all the information
        self.imageDataPos = endIndex;
    }

    fn cleanByteStuffing(self: *Self) !void {
        const startIndex = self.imageDataPos;
        const needle = [_]u8{ 0xff, 0x00 };
        dPrint("[cleanByteStuffing] scanData starts at {x}\n", .{startIndex});
        var zerCount: usize = 0;
        while (std.mem.indexOf(u8, self.data[startIndex..], &needle)) |index| {
            // dPrint("found 0xff, 0x00 at {x}\n", .{startIndex + index});
            _ = self.list.orderedRemove(startIndex + index + 1); // remove the 0x00 byte
            zerCount += 1;
        }
        dPrint("[cleanByteStuffing] found and deleted {d} zeroes\n", .{zerCount});
    }

    fn decodeImageData(self: *Self) !void {
        const startIndex = self.imageDataPos;
        dPrint("imageData startIndex: {x}\n", .{startIndex});
        var i: usize = startIndex;

        const blockCount: usize = @divTrunc(self.pWidth * self.pHeight, 64);
        dPrint("blockCount: {d}\n", .{blockCount});

        var currentComponentIndex: usize = 0;
        var dcs: []u8 = try self.allocator.alloc(u8, self.componentCount);
        _ = dcs;
        var block: Block = undefined;

        var dc: i8 = 0;

        var valueIndex: u6 = 0;
        while (valueIndex < BLOCK_SIZE) {
            const valueType = if (valueIndex == 0) ValueType.Dc else ValueType.Ac; // is this a DC value or an AC value
            const valueTypeIndex = @enumToInt(valueType); // get the index used for accessing arrays
            dPrint("valueType: {?}: {?}\n", .{ valueType, valueTypeIndex });

            const dcAcHuffmantTableSelector = if (valueType == .Dc) self.destinationSelectors[currentComponentIndex].dcDestinationSelector else self.destinationSelectors[currentComponentIndex].acDestinationSelector; // select correct destination
            const huffmanTable = self.huffmanTables[dcAcHuffmantTableSelector][valueTypeIndex]; // select correct destina

            var bitsToRead: u4 = 0; // initilize count of bits to read
            const value: u8 = while (bitsToRead < 15) : (bitsToRead += 1) {
                var buffer = std.io.fixedBufferStream(self.data[i..]);
                var bitReader = std.io.bitReader(JpegEndianness, buffer.reader());
                const bitsRead = try bitReader.readBitsNoEof(u16, bitsToRead + 1);
                // dPrint("bits: {b}\n", .{bitsRead});

                const maybeVal = huffmanTable.get(.{ .length = bitsToRead, .code = bitsRead });
                if (maybeVal) |val| {
                    // dPrint("foundVal: {d}: {b} -> {b}\n", .{ bitsToRead + 1, bitsRead, val });
                    break val;
                }
            } else {
                return ParserError.NoValidHuffmanCodeFound;
            };
            i += (bitsToRead + 1); // move the position forward by how much bits we read

            var buffer = std.io.fixedBufferStream(self.data[i..]);
            var bitReader = std.io.bitReader(JpegEndianness, buffer.reader());

            if (valueType == .Dc) {
                const bitsRead = try bitReader.readBitsNoEof(u8, value);
                const dcValue = @bitCast(i8, bitsRead);
                dPrint("(dc) value: {?}\n", .{dcValue});
                dc += dcValue;
                block.components[currentComponentIndex][0] = dc;
                valueIndex += 1;
            } else {
                const zeroesCount = value & 0b11110000;
                const magnitude = value & 0b00001111;
                dPrint("(ac) zeroes, magnitude: {d}, {d}\n", .{ zeroesCount, magnitude });
                for (0..zeroesCount) |_| valueIndex += 1;
                const bitsRead = try bitReader.readBitsNoEof(u8, magnitude);
                const acValue = @bitCast(i8, bitsRead);
                block.components[currentComponentIndex][valueIndex] = acValue;
            }

            dPrint("found val: {b}\n", .{value});
            dPrint("cci: {d}\n", .{currentComponentIndex});
            currentComponentIndex = (currentComponentIndex + 1) % self.componentCount;
            if (valueIndex == 4) break;
        }
    }

    const ParserError = error{
        NoRequiredMarkerFound,
        NoValidHuffmanCodeFound,
    };
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    // const path = try std.fs.realpath("res/8x8.jpg", &path_buffer);
    const path = try std.fs.realpath("res/8x8.jpg", &path_buffer);

    dPrint("path: {s}\n", .{path});

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
    //     dPrint("{?}, ", .{key});
    // }
}
