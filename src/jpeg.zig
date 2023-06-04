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
    components: [3][BLOCK_SIZE]i8 = std.mem.zeroes([3][BLOCK_SIZE]i8), // NOTE: do i need it?
};

const HuffmanTableHeader = packed struct { // NOTE/HACK: order reversed because of endianness
    destinationIdentifier: u4,
    class: HuffmanTableHeader.ValueType,

    const ValueType = enum(u4) {
        Dc = 0,
        Ac = 1,
    };
};

const QuantizationTableHeader = packed struct { // NOTE/HACK: order reversed because of endianness
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

const ComponentDestinationSelectors = packed struct { // NOTE: why I don't need to reverse order here? or do I still need to do so?
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

    pWidth: usize = undefined,
    pHeight: usize = undefined,

    pub fn init(allocator: std.mem.Allocator, data: []u8) Self {
        const markers = std.AutoHashMap(Marker, MarkerList).init(allocator);
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
        const pp = utils.PrefixPrinter("[parseMarkers] "){};
        pp.print("↓\n", .{});

        var i: usize = 0;
        var sos_found = false;

        var restartInterval: ?u16 = null;
        _ = restartInterval;

        var skipSize: usize = 2;
        while (i < self.data.len) {
            const value = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
            const marker = @intToEnum(Marker, value);

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
                    // restartInterval = std.mem.readIntSlice(u16, self.data[i + 2 .. i + 4], JpegEndianness); // skip two bytes to find the length we need to skip
                    i += 4; // NOTE: HACK
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
        var i: usize = sofList.items[0];

        i += 4; // skip marker and block length

        const precision = self.data[i];
        pp.print("precision: {d}\n", .{precision});
        i += 1;
        const lineCount = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
        pp.print("lineCount: {d}\n", .{lineCount});
        self.pHeight = lineCount;
        i += 2;
        const columnCount = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
        pp.print("columnCount: {d}\n", .{columnCount});
        self.pWidth = lineCount;
        i += 2;
        const imageComponentCount = self.data[i];
        pp.print("imageComponentCount: {d}\n", .{imageComponentCount});
        i += 1;

        const packedComponentSize = 3;

        var destinationIdentifierSet = std.AutoHashMap(u8, void).init(self.allocator);
        defer destinationIdentifierSet.deinit();

        for (0..imageComponentCount) |index| {
            const offset = index * packedComponentSize;
            @memcpy(@ptrCast([*]u8, self.componentTables[index..].ptr), self.data[i + offset .. i + offset + packedComponentSize]); // HACK: unsafe but works :)
            try destinationIdentifierSet.put(self.componentTables[index].qTableDestination, {});
            pp.print("table: {?}\n", .{self.componentTables[index]});
        }

        pp.print("total unique qTables: {d}\n", .{destinationIdentifierSet.count()});
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
            const full_block_length = std.mem.readIntSlice(u16, self.data[i .. i + 2], JpegEndianness);
            i += 2;

            const endIndex = startIndex + 2 + full_block_length;

            while (i < endIndex) {
                const tableClass = @bitCast(HuffmanTableHeader, readInt(u8, &self.data[i]));
                pp.print("HTH: {?}\n", .{tableClass});
                i += 1;

                const lengths = @ptrCast(*const [16]u8, self.data[i .. i + 16]);
                i += 16;

                pp.print("lengths: ", .{});
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
                        // _ = code_map.get(.{ .length = code_index, .code = code_candidate });
                        i += 1;
                        code_candidate += 1;
                    }
                    code_candidate <<= 1; // shift to the left (with zero in front);
                    if (code_index != 15) code_index += 1 else break;
                }

                var kvIt = code_map.iterator();
                while (kvIt.next()) |kv| {
                    pp.print("kv: {d}: {b:0>16} -> {b:0>8}\n", .{ kv.key_ptr.*.length, kv.key_ptr.*.code, kv.value_ptr.* });
                }

                pp.print("will set this table at [{d}][{d}]\n", .{ tableClass.destinationIdentifier, @enumToInt(tableClass.class) });
                self.huffmanTables[tableClass.destinationIdentifier][@enumToInt(tableClass.class)] = code_map;
            }
        }

        pp.print("↑\n\n", .{});
    }

    fn decodeQuantizationTables(self: *Self) !void {
        const pp = utils.PrefixPrinter("[decodeQuantizationTables] "){};
        pp.print("↓\n", .{});

        var qtList: MarkerList = self.markers.get(Marker.quantizationTable) orelse return ParserError.NoRequiredMarkerFound;
        std.debug.assert(qtList.items.len >= 1);

        for (qtList.items) |startIndex| {
            var i: usize = startIndex;
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

                pp.print("{?}\n", .{self.quantizationTables[qIndex]});

                i += 64;
            }
        }

        pp.print("↑\n\n", .{});
    }

    fn decodeStarOfScan(self: *Self) !void {
        const pp = utils.PrefixPrinter("[decodeSoF] "){};
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

        for (0..componentCount) |componentIndex| {
            const id = readInt(u8, &self.data[i]);
            i += 1;
            const destinationSelectors = @bitCast(ComponentDestinationSelectors, readInt(u8, &self.data[i]));
            i += 1;

            pp.print("cih: {?}, {?}\n", .{ id, destinationSelectors });

            self.destinationSelectors[componentIndex] = destinationSelectors;
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

    fn cleanByteStuffing(self: *Self) !void {
        const pp = utils.PrefixPrinter("[cleanByteStuffing] "){};
        pp.print("↓\n", .{});

        const startIndex = self.imageDataPos;
        const needle = [_]u8{ 0xff, 0x00 };
        pp.print("scanData starts at {x}\n", .{startIndex});
        var zerCount: usize = 0;
        while (std.mem.indexOf(u8, self.data[startIndex..], &needle)) |index| {
            // pp.print("found 0xff, 0x00 at {x}\n", .{startIndex + index});
            _ = self.list.orderedRemove(startIndex + index + 1); // remove the 0x00 byte
            zerCount += 1;
        }
        pp.print("found and deleted {d} zeroes\n", .{zerCount});
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

        const blockCount: usize = @divTrunc(self.pWidth * self.pHeight, 64);
        pp.print("blockCount: {d}\n", .{blockCount});

        var dcs: []i8 = try self.allocator.alloc(i8, self.componentCount);
        var blocks: []Block = try self.allocator.alloc(Block, blockCount);

        var valueIndex: u6 = 0;

        pp.print("beginning with i: {x}\n", .{i});
        var buffer = std.io.fixedBufferStream(self.data[i..]);
        var bitReader = std.io.bitReader(JpegEndianness, buffer.reader());

        var currentBlockIndex: usize = 0;
        while (currentBlockIndex < blockCount) : (currentBlockIndex += 1) {
            pp.print("currentBlockIndex: {d}\n", .{currentBlockIndex});
            var currentComponentIndex: usize = 0;
            var currentComopnentDC: i8 = dcs[currentComponentIndex];
            while (currentComponentIndex < self.componentCount) : (currentComponentIndex += 1) {
                pp.print("currentComponentIndex: {d}\n", .{currentComponentIndex});
                while (valueIndex < BLOCK_SIZE - 1) {
                    const valueType = if (valueIndex == 0) ValueType.Dc else ValueType.Ac; // is this a DC value or an AC value
                    const valueTypeIndex = @enumToInt(valueType); // get the index used for accessing arrays
                    // pp.print("valueType: {?}: {?}\n", .{ valueType, valueTypeIndex });

                    // NOTE: am i selecting the right tables? most likely not, as the code overruns EOF

                    // pp.print("componentIndex: {d}\n", .{currentComponentIndex});
                    const destinationSelector = if (valueType == .Dc) self.destinationSelectors[currentComponentIndex].dcDestinationSelector else self.destinationSelectors[currentComponentIndex].acDestinationSelector; // select correct destination
                    const huffmanTable = self.huffmanTables[destinationSelector][valueTypeIndex]; // select correct destination
                    // pp.print("huffmanTable: [{d}][{d}]\n", .{ destinationSelector, valueTypeIndex });

                    // pp.print("bufPos before: {x}\n", .{startIndex + buffer.pos});
                    var bitsToRead: u4 = 0; // initilize count of bits to read (actualBits - 1)
                    // save the buffer position and bitReader state to restore it later, in case we need to read more bits starting from the same position
                    const currBufPos = buffer.pos;
                    const savedBitReader = bitReader;
                    const value: u8 = while (bitsToRead < 15) : (bitsToRead += 1) {
                        // pp.print("bufPos inside, before reading: {d}\n", .{buffer.pos});
                        const bitsRead = try bitReader.readBitsNoEof(u16, bitsToRead + 1);
                        // pp.print("bits: {b}\n", .{bitsRead});

                        // pp.print("bufPos inside, after reading: {d}\n", .{buffer.pos});
                        pp.print("trying to get length, code: {d}, {b:0>16}\n", .{ bitsToRead + 1, bitsRead });
                        const maybeVal = huffmanTable.get(.{ .length = bitsToRead, .code = bitsRead });
                        if (maybeVal) |val| {
                            pp.print("length, code: val: {d}, {b:0>16} {b:0>8}\n", .{ bitsToRead + 1, bitsRead, val });
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

                    pp.print("foundVal: {b:0>8}\n", .{value});

                    if (valueType == .Dc) {
                        const bitsRead = try bitReader.readBitsNoEof(u8, value);
                        const dcValue = @bitCast(i8, bitsRead);
                        pp.print("(dc) magnitude, value: {d} {b:0>8}\n", .{ value, bitsRead });
                        currentComopnentDC += dcValue;
                        blocks[currentBlockIndex].components[currentComponentIndex][0] = currentComopnentDC;
                    } else {
                        const zeroesCount: u8 = @shrExact(value & 0b11110000, 4);
                        const magnitude: u8 = value & 0b00001111;
                        pp.print("(ac) zeroes, magnitude: {d}, {d}\n", .{ zeroesCount, magnitude });
                        if (zeroesCount == 0 and magnitude == 0) {
                            pp.print("FOUND EOB!\n", .{});
                            break;
                        }
                        valueIndex += @truncate(u6, zeroesCount); // NOTE: this is safe, maybe do it above?
                        const bitsRead = try bitReader.readBitsNoEof(u8, magnitude);
                        pp.print("(ac) value: {b:0>8}\n", .{bitsRead});
                        const acValue = @bitCast(i8, bitsRead);
                        blocks[currentBlockIndex].components[currentComponentIndex][valueIndex] = acValue;
                    }
                    valueIndex += 1;
                    pp.print("valueIndex: {d}\n", .{valueIndex});

                    // pp.print("found val: {b}\n", .{value});
                    // pp.print("cci: {d}\n", .{currentComponentIndex});
                    // currentComponentIndex = (currentComponentIndex + 1) % self.componentCount;
                    // if (valueIndex == 4) break;
                }
            }
        }
        pp.print("↑\n\n", .{});
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
