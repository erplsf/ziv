// TODO: add RST marker handling
const std = @import("std");
const utils = @import("utils.zig");
const SkippingReader = @import("skipping_reader.zig").SkippingReader;

const JpegEndianness = std.builtin.Endian.Big;
const dPrint = std.debug.print;
const readInt = std.mem.readIntBig;
const readIntSlice = std.mem.readIntSliceBig;
const BLOCK_SIZE = 8 * 8;

const ValueType = enum(u1) {
    Dc = 0,
    Ac = 1,
};

const SKIPPING_PATTERN: []const u8 = &[_]u8{
    0xFF,
    0x00,
};

const Marker = enum(u16) { // TODO: validate that all markers are handled/parsed correctly
    startOfImage = 0xffd8, // NOTE: validated: noop, just a start marker
    // app0 = 0xffe0, // NOTE: these are not relevant/used atm
    // app1 = 0xffe1,
    // app2 = 0xffe2,
    // app13 = 0xffed,
    // app14 = 0xffee,
    quantizationTable = 0xffdb, // NOTE: validated: all data looks ok
    startOfFrame0 = 0xffc0, // NOTE: validated: all data looks ok
    defineHuffmanTable = 0xffc4, // NOTE: validated: all data looks ok
    startOfScan = 0xffda,
    endOfImage = 0xffd9,
    defineRestartInterval = 0xffdd,
    _,
};

const Block = struct {
    components: [3]@Vector(BLOCK_SIZE, i8),
};

const FrameHeader = packed struct {
    componentCount: u8,
    samplesPerLine: u16,
    lineCount: u16,
    samplePrecision: u8,
};

const HuffmanTableHeader = packed struct { // NOTE: Order is LSB (reverse)
    destinationIdentifier: u4,
    class: Class,

    const Class = enum(u4) {
        Dc = 0,
        Ac = 1,
    };
};

const QuantizationTableHeader = packed struct { // NOTE: Order is LSB (reverse)
    destinationIdentifier: u4,
    precision: Precision,

    const Precision = enum(u4) {
        @"8bit" = 0,
        @"16bit" = 1,
    };
};

const QuantizationTable = struct {
    header: QuantizationTableHeader,
    table: @Vector(64, u8), // NOTE: it's always u8 for Sequential DCT
};

const ComponentInformation = packed struct { // NOTE: Order is LSB (reverse)
    qTableDestination: u8,
    verticalSamples: u4,
    horizontalSamples: u4,
    id: Type, // NOTE: component identifier (1 = Y, 2 = Cb, 3 = Cr) according to JFIF standard

    const Type = enum(u8) {
        Y = 1,
        Cb = 2,
        Cr = 3,
    };
};

const ComponentDestinationSelectors = packed struct { // NOTE: Order is LSB (reverse)
    acDestinationSelector: u4,
    dcDestinationSelector: u4,
};

const HTKey = struct {
    length: u8,
    code: u16,
};

const HuffmanTable = std.AutoHashMap(HTKey, u8); // pairing between length and code to value

const Parser = struct {
    const Self = @This();
    const MarkerList = std.ArrayList(usize);

    allocator: std.mem.Allocator,
    list: std.ArrayList(u8),
    data: []u8,
    imageDataPos: usize = undefined,
    imageDataEnd: usize = undefined,

    markers: std.AutoHashMap(Marker, MarkerList),
    componentTables: [3]ComponentInformation = undefined, // HACK: hardcoded numbers for JFIF Y/Cb/Cr
    huffmanTables: [2][2]HuffmanTable = undefined, // HACK: hardcoded numbers for baseline sequential DCT
    quantizationTables: [2]QuantizationTable = undefined,
    componentCount: usize = undefined,
    destinationSelectors: [3]ComponentDestinationSelectors = undefined,

    frameHeader: FrameHeader = undefined,

    rawBlocks: []Block = undefined,

    restartInterval: ?u16 = null,

    pub fn init(allocator: std.mem.Allocator, data: []u8) Self {
        const markers = std.AutoHashMap(Marker, MarkerList).init(allocator);
        const list = std.ArrayList(u8).fromOwnedSlice(allocator, data);
        return .{ .allocator = allocator, .list = list, .data = list.items, .markers = markers };
    }

    pub fn deinit(self: *Self) void {
        self.markers.deinit();
        for (0..2) |dcAc| {
            for (0..2) |destination| {
                self.huffmanTables[destination][dcAc].deinit();
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
        try self.decodeImageData();
        try self.dequantizeBlocks();
    }

    pub fn parseMarkers(self: *Self) !void {
        const pp = utils.PrefixPrinter("[parseMarkers] "){};
        pp.print("↓\n", .{});

        var i: usize = 0;
        var sos_found = false;

        var skipSize: usize = 2;
        while (i < self.data.len) {
            const value = readIntSlice(u16, self.data[i .. i + 2]);
            const marker = @as(Marker, @enumFromInt(value));

            // pp.print("{d} < {d} skipSize: {d}\n", .{ i, self.data.len, skipSize });
            // pp.print("{x} 0x{?} -> ", .{ i, std.fmt.fmtSliceHexLower(self.data[i .. i + 2]) });

            if (!sos_found or marker == .endOfImage) { // no SoS marker found, treat all data as tokens
                pp.print("{x} 0x{?} -> ", .{ i, std.fmt.fmtSliceHexLower(self.data[i .. i + 2]) });
                dPrint("{?}\n", .{marker});
            }

            var entry = try self.markers.getOrPut(marker);
            if (!entry.found_existing) {
                var list = MarkerList.init(self.allocator);
                entry.value_ptr.* = list;
            }

            try entry.value_ptr.*.append(i);

            if (marker == .endOfImage) {
                self.imageDataEnd = i;
                break;
            }

            if (sos_found) {
                i += skipSize;
                continue;
            }

            switch (marker) {
                .startOfImage => {},
                .endOfImage => {
                    break;
                },
                .defineRestartInterval => {
                    const block_length = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], JpegEndianness); // skip two bytes to find the length we need to skip
                    self.restartInterval = std.mem.readIntSlice(u16, self.data[i + 4 .. i + 6], JpegEndianness); // skip two bytes to find the length we need to skip
                    i += block_length; // NOTE: HACK
                },
                .startOfScan => { // found "Start Of Scan" marker, all following data is raw data, start brute-force search for end token
                    sos_found = true;
                    skipSize = 1;
                },
                else => {
                    const block_length = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], JpegEndianness); // skip two bytes to find the length we need to skip
                    // pp.print("block length: 0x{?} -> {d}\n", .{ std.fmt.fmtSliceHexLower(self.data[i + 2 .. i + 4]), block_length });
                    i += block_length;
                },
            }
            i += skipSize;
        }
        pp.print("↑\n\n", .{});
    }

    // NOTE: we only support SOF0
    fn decodeSoF(self: *Self) !void {
        const pp = utils.PrefixPrinter("[decodeSoF] "){};
        pp.print("↓\n", .{});

        var sofList: MarkerList = self.markers.get(Marker.startOfFrame0) orelse return ParserError.NoRequiredMarkerFound;
        std.debug.assert(sofList.items.len == 1);

        const startPos = sofList.items[0] + 2; // skip the marker itself
        var i: usize = startPos;

        const block_length = readIntSlice(u16, self.data[i .. i + 2]);
        i += 2; // skip block length

        const FrameBitsSize = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = @bitSizeOf(FrameHeader) } });
        const frameByteSize = @bitSizeOf(FrameHeader) / @bitSizeOf(u8);

        self.frameHeader = @as(FrameHeader, @bitCast(readIntSlice(FrameBitsSize, self.data[i .. i + frameByteSize])));
        pp.print("{?}\n", .{self.frameHeader});
        i += frameByteSize;

        const TypeBitsSize = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = @bitSizeOf(ComponentInformation) } });
        const byteSize = @bitSizeOf(ComponentInformation) / @bitSizeOf(u8);
        // pp.print("size: {d} {d}\n", .{ packedComponentSize, byteSize });

        for (0..self.frameHeader.componentCount) |index| {
            self.componentTables[index] = @as(ComponentInformation, @bitCast(readIntSlice(TypeBitsSize, self.data[i .. i + byteSize])));
            pp.print("table: {?}\n", .{self.componentTables[index]});
            i += byteSize;
        }

        // pp.print("startPos: {d} blockLength: {d}, sum: {d} == finalPos: {d}", .{ startPos, block_length, startPos + block_length, i });
        std.debug.assert(startPos + block_length == i); // assert that we parsed exactly as many bytes as we needed to

        pp.print("↑\n\n", .{});
    }

    fn buildHuffmanTables(self: *Self) !void {
        const pp = utils.PrefixPrinter("[buildHuffmanTables] "){};
        pp.print("↓\n", .{});

        var htList: MarkerList = self.markers.get(Marker.defineHuffmanTable) orelse return ParserError.NoRequiredMarkerFound;
        std.debug.assert(htList.items.len >= 1);

        pp.print("found {d} markers\n", .{htList.items.len});
        for (htList.items) |startIndex| {
            var i: usize = startIndex;
            i += 2; // skip marker
            const full_block_length = readIntSlice(u16, self.data[i .. i + 2]);
            i += 2;

            const endIndex = startIndex + 2 + full_block_length;

            while (i < endIndex) {
                const tableHeader: HuffmanTableHeader = @as(HuffmanTableHeader, @bitCast(self.data[i]));
                pp.print("HTH: {?}\n", .{tableHeader});
                i += 1;

                const lengths = @as(*const [16]u8, @ptrCast(self.data[i .. i + 16]));
                i += 16;

                pp.print("lengths: ", .{});
                utils.slicePrint(u8, lengths);
                dPrint("\n", .{});

                var code_map = HuffmanTable.init(self.allocator);
                var code_candidate: u16 = 0;
                var code_index: u8 = 0;

                while (true) { // TODO: check if this is correct
                    const code_count_for_index = lengths[code_index];
                    var current_code_index: usize = 0;
                    while (current_code_index < code_count_for_index) : (current_code_index += 1) {
                        const value = readInt(u8, &self.data[i]);
                        try code_map.put(.{ .length = code_index + 1, .code = code_candidate }, value);
                        // _ = code_map.get(.{ .length = code_index, .code = code_candidate });
                        i += 1;
                        code_candidate += 1;
                    }
                    code_candidate <<= 1; // shift to the left (with zero in front);
                    if (code_index != 15) code_index += 1 else break;
                }

                // var kvIt = code_map.iterator();
                // while (kvIt.next()) |kv| {
                //     pp.print("kv: {d}: {b:0>16} -> {b:0>8}\n", .{ kv.key_ptr.*.length, kv.key_ptr.*.code, kv.value_ptr.* });
                // }

                pp.print("will set this table at [{d}][{d}]\n", .{ tableHeader.destinationIdentifier, @intFromEnum(tableHeader.class) });
                self.huffmanTables[tableHeader.destinationIdentifier][@intFromEnum(tableHeader.class)] = code_map;
            }
        }

        pp.print("↑\n\n", .{});
    }

    fn decodeQuantizationTables(self: *Self) !void {
        const pp = utils.PrefixPrinter("[decodeQuantizationTables] "){};
        pp.print("↓\n", .{});

        var qtList: MarkerList = self.markers.get(Marker.quantizationTable) orelse return ParserError.NoRequiredMarkerFound;
        std.debug.assert(qtList.items.len >= 1);

        var qIndex: usize = 0;
        for (qtList.items) |startIndex| {
            var i: usize = startIndex;
            i += 2; // skip marker
            const full_block_length = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
            i += 2;

            const endIndex = (startIndex + 2) + full_block_length;

            while (i < endIndex) {
                // pp.print("0x{x}\n", .{i});
                const tableHeader = @as(QuantizationTableHeader, @bitCast(self.data[i]));
                i += 1;

                const elements = @as(*const [64]u8, @ptrCast(self.data[i .. i + 64]));
                var table: @Vector(64, u8) = elements.*;

                self.quantizationTables[qIndex].header = tableHeader;
                self.quantizationTables[qIndex].table = table;

                pp.print("will set qTable at [{d}]\n", .{qIndex});
                pp.print("{?}\n", .{self.quantizationTables[qIndex]});

                i += 64;
            }
            qIndex += 1;
        }

        pp.print("↑\n\n", .{});
    }

    fn decodeStarOfScan(self: *Self) !void {
        const pp = utils.PrefixPrinter("[decodeSoS] "){};
        pp.print("↓\n", .{});

        const sosList: MarkerList = self.markers.get(Marker.startOfScan) orelse return ParserError.NoRequiredMarkerFound;
        std.debug.assert(sosList.items.len == 1);

        const startIndex = sosList.items[0];
        var i: usize = startIndex;
        i += 2;

        const blockLength = readIntSlice(u16, self.data[i .. i + 2]);
        const endIndex = i + blockLength;
        i += 2;

        const componentCount = readInt(u8, &self.data[i]);
        pp.print("componentCount: {d}\n", .{componentCount});
        self.componentCount = componentCount;
        i += 1;

        for (0..componentCount) |_| {
            const id = readInt(u8, &self.data[i]); // TODO: save id mapping for later use in image decoding (to preserve the right order)
            i += 1;
            const destinationSelectors = @as(ComponentDestinationSelectors, @bitCast(self.data[i]));
            i += 1;

            pp.print("cih: {?}, {?}\n", .{ id, destinationSelectors });

            std.debug.assert(id - 1 >= 0);
            self.destinationSelectors[id - 1] = destinationSelectors;
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
        pp.print("↑\n\n", .{});
    }

    fn decodeImageData(self: *Self) !void {
        const pp = utils.PrefixPrinter("[decodeImageData] "){};
        pp.print("↓\n", .{});
        // pp.print("↑\n\n", .{});

        const startIndex = self.imageDataPos;
        pp.print("imageData startIndex: {d}\n", .{startIndex});
        pp.print("imageData length (bytes): {d}\n", .{self.imageDataEnd - self.imageDataPos});
        var i: usize = startIndex;

        const blockCount: usize = @divTrunc(@as(usize, self.frameHeader.lineCount) * @as(usize, self.frameHeader.samplesPerLine), 64); // HACK: is it the right calculation?
        pp.print("blockCount: {d}\n", .{blockCount});

        var dcs: []i8 = try self.allocator.alloc(i8, self.componentCount);
        for (dcs) |*dc| dc.* = 0;

        var blocks: []Block = try self.allocator.alloc(Block, blockCount);

        pp.print("beginning with i: {x}\n", .{i});
        var buffer = std.io.fixedBufferStream(self.data[i..]);
        var skippingReader = SkippingReader(@TypeOf(buffer.reader()), SKIPPING_PATTERN, 1){ .inner_reader = buffer.reader() };
        var reader = skippingReader.reader();
        var bitReader = std.io.bitReader(JpegEndianness, reader);

        var currentBlockIndex: usize = 0;

        if (self.restartInterval) |interval| {
            pp.print("restartInterval: {d}\n", .{interval});
        }

        while (currentBlockIndex < blockCount) : (currentBlockIndex += 1) {
            pp.print("currentBlockIndex: {d}\n", .{currentBlockIndex});
            pp.print("index: {x}\n", .{i + buffer.pos});
            var currentComponentIndex: usize = 0;
            while (currentComponentIndex < self.componentCount) : (currentComponentIndex += 1) {
                blocks[currentBlockIndex].components[currentComponentIndex] = std.mem.zeroes(@Vector(BLOCK_SIZE, i8));

                var currentComopnentDC: i8 = dcs[currentComponentIndex];
                // pp.print("currentDC: {d}\n", .{currentComopnentDC});
                var valueIndex: u8 = 0;
                pp.print("currentComponentIndex: {d}\n", .{currentComponentIndex});
                while (valueIndex < BLOCK_SIZE) {
                    const valueType = if (valueIndex == 0) ValueType.Dc else ValueType.Ac; // is this a DC value or an AC value
                    const valueTypeIndex = @intFromEnum(valueType); // get the index used for accessing arrays
                    // pp.print("valueType: {?}: {?}\n", .{ valueType, valueTypeIndex });

                    // NOTE: am i selecting the right tables? most likely not, as the code overruns EOF

                    // pp.print("componentIndex: {d}\n", .{currentComponentIndex});
                    const destinationSelector = if (valueType == .Dc) self.destinationSelectors[currentComponentIndex].dcDestinationSelector else self.destinationSelectors[currentComponentIndex].acDestinationSelector; // select correct destination
                    const huffmanTable = self.huffmanTables[destinationSelector][valueTypeIndex]; // select correct destination
                    // pp.print("huffmanTable: [{d}][{d}]\n", .{ destinationSelector, valueTypeIndex });

                    // TODO: refactor this section with saving/restoring bit reader
                    // pp.print("bufPos before: {x}\n", .{startIndex + buffer.pos});
                    var bitsToRead: u8 = 1; // initilize count of bits to read (actualBits - 1)
                    // save the buffer position and bitReader state to restore it later, in case we need to read more bits starting from the same position
                    const currBufPos = buffer.pos;
                    const savedBitReader = bitReader;
                    const value: u8 = while (bitsToRead <= 16) : (bitsToRead += 1) {
                        // pp.print("bufPos inside, before reading: {d}\n", .{buffer.pos});
                        const bitsRead = try bitReader.readBitsNoEof(u16, bitsToRead);
                        // pp.print("bits: {b}\n", .{bitsRead});

                        // pp.print("bufPos inside, after reading: {d}\n", .{buffer.pos});
                        // pp.print("trying to get length, code: {d}, {b:0>16}\n", .{ bitsToRead + 1, bitsRead });
                        const maybeVal = huffmanTable.get(.{ .length = bitsToRead, .code = bitsRead });
                        if (maybeVal) |val| {
                            // pp.print("length, code: val: {d}, {b:0>16} {b:0>8}\n", .{ bitsToRead + 1, bitsRead, val });
                            break val;
                        }
                        bitReader = savedBitReader;
                        buffer.pos = currBufPos;
                        // buffer.pos = currBufPos; // revert buffer position to try to read more bits from beginning
                        // bitReader = std.io.bitReader(JpegEndianness, buffer.reader());
                        // pp.print("bufPos inside, after substract: {d}\n", .{buffer.pos});
                    } else return ParserError.NoValidHuffmanCodeFound;
                    // buffer.pos += (bitsToRead + 1); // we have the value here, move buffer forward
                    // bitReader = std.io.bitReader(JpegEndianness, buffer.reader());
                    // pp.print("bufPos after: {d}\n", .{buffer.pos});

                    // pp.print("foundVal: {b:0>8}\n", .{value});
                    // TODO: end of "refactor this section"

                    // pp.print("valueIndex: {d}\n", .{valueIndex});
                    if (valueType == .Dc) {
                        // pp.print("trying to read dc value of {d} bits\n", .{value});
                        std.debug.assert(value >= 0);
                        const bitsRead = try bitReader.readBitsNoEof(u8, value);
                        const dcValue = @as(i8, @bitCast(bitsRead));
                        // pp.print("(dc) magnitude, value: {d} {d}\n", .{ value, dcValue });
                        currentComopnentDC += dcValue;
                        // pp.print("(dc) newCurrentDC: {d}\n", .{currentComopnentDC});
                        blocks[currentBlockIndex].components[currentComponentIndex][0] = currentComopnentDC;

                        valueIndex += 1;
                    } else {
                        const zeroesCount: u8 = @shrExact(value & 0b11110000, 4);
                        const magnitude: u8 = value & 0b00001111;
                        // pp.print("(ac) zeroes, magnitude: {d}, {d}\n", .{ zeroesCount, magnitude });
                        if (zeroesCount == 0 and magnitude == 0) {
                            pp.print("FOUND EOB!\n", .{});
                            break;
                        }
                        // pp.print("zeroCount: {d}\n", .{zeroesCount});
                        // std.os.exit(0);

                        valueIndex += zeroesCount;
                        // for (0..@as(u6, @truncate(zeroesCount))) |zc| {
                        //     _ = zc;
                        //     // NOTE: this is safe, maybe do it above?
                        //     pp.print("Zero filling\n", .{});
                        //     // const localIndex = @min(valueIndex + zc, BLOCK_SIZE - 1);
                        //     blocks[currentBlockIndex].components[currentComponentIndex][valueIndex] = 0;
                        //     // if (localIndex == BLOCK_SIZE - 1) break;
                        //     valueIndex += 1;
                        // }

                        // if (valueIndex >= BLOCK_SIZE) {
                        //     break;
                        // }

                        // pp.print("magnitude: {d}\n", .{magnitude});
                        const bitsRead = try bitReader.readBitsNoEof(u8, magnitude);
                        const acValue = @as(i8, @bitCast(bitsRead));
                        // pp.print("(ac) value: {d}\n", .{acValue});
                        blocks[currentBlockIndex].components[currentComponentIndex][valueIndex] = acValue;
                    }
                    // pp.print("value index: {d}\n", .{valueIndex});
                    // valueIndex += 1; // TODO: this overflows!
                    // pp.print("valueIndex: {d}\n", .{valueIndex});

                    // pp.print("found val: {b}\n", .{value});
                    // pp.print("cci: {d}\n", .{currentComponentIndex});
                    // currentComponentIndex = (currentComponentIndex + 1) % self.componentCount;
                    // if (valueIndex == 4) break;
                }
                // pp.print("finalBlock: {?}\n", .{blocks[currentBlockIndex].components[currentComponentIndex]});
            }
            if (self.restartInterval) |restartInterval| {
                if ((currentBlockIndex + 1) % restartInterval == 0) {
                    pp.print("SHOULD RESTART NOW!\n", .{});
                    for (dcs) |*dc| dc.* = 0;
                    { // TODO: this section doesn't work! why `alignToByte` doesn't work?
                        bitReader.alignToByte();
                    }
                }
            }
        }
        self.rawBlocks = blocks;
        pp.print("↑\n\n", .{});
    }

    fn dequantizeBlocks(self: *Self) !void {
        for (self.rawBlocks) |*block| {
            for (0..self.componentCount) |currentComponentIndex| {
                const qTableIndex = self.componentTables[currentComponentIndex].qTableDestination;
                std.debug.print("block: {?}\n", .{block.components[currentComponentIndex]});
                std.debug.print("qTable: {?}\n", .{self.quantizationTables[qTableIndex].table});
                block.components[currentComponentIndex] *= @as(@Vector(BLOCK_SIZE, i8), @intCast(self.quantizationTables[qTableIndex].table));
                std.debug.print("{?}\n", .{block.components[currentComponentIndex]});
            }
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

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip first arg, which is a filename

    const filename = args.next().?; // fetch the first argument, which must be present

    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.fs.realpath(filename, &path_buffer);

    dPrint("[main] file path: {s}\n\n", .{path});

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
