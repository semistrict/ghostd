const std = @import("std");

pub const DEFAULT_COLOR: u16 = 256;
pub const MAX_CELL_RANGE_LEN: usize = 32;

pub const ClientOpcode = enum(u8) {
    input = 1,
    resize = 2,
    claim_writer = 3,
    scroll = 4,
    list_terminals = 5,
    create_terminal = 6,
    close_terminal = 7,
};

pub const ServerOpcode = enum(u8) {
    snapshot = 1,
    rows = 2,
    role = 3,
    exit = 4,
    terminals = 5,
    terminal_created = 6,
    terminal_closed = 7,
};

pub const WireRole = enum(u8) {
    reader = 0,
    writer = 1,
};

pub const ScrollDirection = enum(u8) {
    up = 0,
    down = 1,
};

pub const Cell = struct {
    char: u32,
    fg: u16 = DEFAULT_COLOR,
    bg: u16 = DEFAULT_COLOR,
    flags: u8 = 0,
    fg_rgb: ?u24 = null,
    bg_rgb: ?u24 = null,
};

pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    mouse_reporting: bool,
    cells: []Cell,
};

pub const CellRange = struct {
    row: u16,
    col: u16,
    len: u16,
};

pub const ClientMessage = union(enum) {
    input: struct { terminal_id: u32, data: []const u8 },
    resize: struct { terminal_id: u32, cols: u16, rows: u16 },
    scroll: struct { terminal_id: u32, rows: u16, direction: ScrollDirection },
    claim_writer: struct { terminal_id: u32 },
    list_terminals,
    create_terminal: struct { cols: u16, rows: u16 },
    close_terminal: struct { terminal_id: u32 },
    unknown,
};

pub const MsgpackWriter = struct {
    buf: std.array_list.Managed(u8),

    pub fn init(alloc: std.mem.Allocator) MsgpackWriter {
        return .{ .buf = std.array_list.Managed(u8).init(alloc) };
    }

    pub fn deinit(self: *MsgpackWriter) void {
        self.buf.deinit();
    }

    pub fn bytes(self: *const MsgpackWriter) []const u8 {
        return self.buf.items;
    }

    pub fn byte(self: *MsgpackWriter, value: u8) !void {
        try self.buf.append(value);
    }

    pub fn str(self: *MsgpackWriter, value: []const u8) !void {
        if (value.len <= 31) {
            try self.byte(0xa0 | @as(u8, @intCast(value.len)));
        } else if (value.len <= 0xff) {
            try self.byte(0xd9);
            try self.byte(@intCast(value.len));
        } else {
            try self.byte(0xda);
            try self.u16be(@intCast(value.len));
        }
        try self.buf.appendSlice(value);
    }

    pub fn map(self: *MsgpackWriter, len: u16) !void {
        if (len <= 15) {
            try self.byte(0x80 | @as(u8, @intCast(len)));
        } else {
            try self.byte(0xde);
            try self.u16be(len);
        }
    }

    pub fn array(self: *MsgpackWriter, len: u32) !void {
        if (len <= 15) {
            try self.byte(0x90 | @as(u8, @intCast(len)));
        } else if (len <= 0xffff) {
            try self.byte(0xdc);
            try self.u16be(@intCast(len));
        } else {
            try self.byte(0xdd);
            try self.u32be(len);
        }
    }

    pub fn boolValue(self: *MsgpackWriter, value: bool) !void {
        try self.byte(if (value) 0xc3 else 0xc2);
    }

    pub fn nilValue(self: *MsgpackWriter) !void {
        try self.byte(0xc0);
    }

    pub fn uint(self: *MsgpackWriter, value: u32) !void {
        if (value <= 0x7f) {
            try self.byte(@intCast(value));
        } else if (value <= 0xff) {
            try self.byte(0xcc);
            try self.byte(@intCast(value));
        } else if (value <= 0xffff) {
            try self.byte(0xcd);
            try self.u16be(@intCast(value));
        } else {
            try self.byte(0xce);
            try self.u32be(value);
        }
    }

    fn u16be(self: *MsgpackWriter, value: u16) !void {
        try self.byte(@intCast(value >> 8));
        try self.byte(@intCast(value & 0xff));
    }

    fn u32be(self: *MsgpackWriter, value: u32) !void {
        try self.byte(@intCast((value >> 24) & 0xff));
        try self.byte(@intCast((value >> 16) & 0xff));
        try self.byte(@intCast((value >> 8) & 0xff));
        try self.byte(@intCast(value & 0xff));
    }
};

fn encodeCell(writer: *MsgpackWriter, cell: Cell) !void {
    const has_rgb = cell.fg_rgb != null or cell.bg_rgb != null;
    try writer.array(if (has_rgb) 6 else 4);
    try writer.uint(if (cell.char == 0) 32 else cell.char);
    try writer.uint(cell.fg);
    try writer.uint(cell.bg);
    try writer.uint(cell.flags);
    if (has_rgb) {
        if (cell.fg_rgb) |rgb| {
            try writer.uint(rgb);
        } else {
            try writer.nilValue();
        }
        if (cell.bg_rgb) |rgb| {
            try writer.uint(rgb);
        } else {
            try writer.nilValue();
        }
    }
}

pub fn encodeSnapshot(alloc: std.mem.Allocator, terminal_id: u32, snap: Snapshot, role: WireRole) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();

    try writer.array(10);
    try writer.uint(@intFromEnum(ServerOpcode.snapshot));
    try writer.uint(terminal_id);
    try writer.uint(snap.cols);
    try writer.uint(snap.rows);
    try writer.uint(@intFromEnum(role));
    try writer.array(3);
    try writer.uint(snap.cursor_row);
    try writer.uint(snap.cursor_col);
    try writer.boolValue(snap.cursor_visible);
    try writer.boolValue(snap.mouse_reporting);
    try writer.array(0);
    try writer.array(0);
    try writer.array(snap.rows);
    for (0..snap.rows) |row| {
        try writer.array(2);
        try writer.uint(@intCast(row));
        try writer.array(snap.cols);
        const start = row * @as(usize, snap.cols);
        for (snap.cells[start .. start + snap.cols]) |cell| {
            try encodeCell(&writer, cell);
        }
    }

    return writer.buf.toOwnedSlice();
}

pub fn buildChangedRanges(
    alloc: std.mem.Allocator,
    previous: []const Cell,
    current: []const Cell,
    cols: u16,
    rows: u16,
) !std.array_list.Managed(CellRange) {
    std.debug.assert(previous.len == current.len);
    std.debug.assert(previous.len == @as(usize, cols) * @as(usize, rows));

    var ranges = std.array_list.Managed(CellRange).init(alloc);
    errdefer ranges.deinit();

    for (0..rows) |row| {
        var col: usize = 0;
        while (col < cols) {
            const cell_index = row * @as(usize, cols) + col;
            if (std.meta.eql(previous[cell_index], current[cell_index])) {
                col += 1;
                continue;
            }

            const range_start = col;
            col += 1;
            while (col < cols) : (col += 1) {
                const next_index = row * @as(usize, cols) + col;
                if (std.meta.eql(previous[next_index], current[next_index])) break;
            }

            var chunk_start = range_start;
            while (chunk_start < col) {
                const chunk_len = @min(MAX_CELL_RANGE_LEN, col - chunk_start);
                try ranges.append(.{
                    .row = @intCast(row),
                    .col = @intCast(chunk_start),
                    .len = @intCast(chunk_len),
                });
                chunk_start += chunk_len;
            }
        }
    }

    return ranges;
}

pub fn encodeRows(alloc: std.mem.Allocator, terminal_id: u32, snap: Snapshot, ranges: []const CellRange) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();

    try writer.array(4);
    try writer.uint(@intFromEnum(ServerOpcode.rows));
    try writer.uint(terminal_id);
    try writer.array(3);
    try writer.uint(snap.cursor_row);
    try writer.uint(snap.cursor_col);
    try writer.boolValue(snap.cursor_visible);
    try writer.array(@intCast(ranges.len));
    for (ranges) |range| {
        try writer.array(3);
        try writer.uint(range.row);
        try writer.uint(range.col);
        try writer.array(range.len);
        const start = @as(usize, range.row) * @as(usize, snap.cols) + @as(usize, range.col);
        for (snap.cells[start .. start + range.len]) |cell| {
            try encodeCell(&writer, cell);
        }
    }

    return writer.buf.toOwnedSlice();
}

const MsgpackReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(self: *MsgpackReader) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    fn readLen(self: *MsgpackReader, marker: u8) !usize {
        return switch (marker) {
            0x80...0x8f => marker & 0x0f,
            0xde => try self.readU16(),
            0xdf => try self.readU32(),
            0x90...0x9f => marker & 0x0f,
            0xdc => try self.readU16(),
            0xdd => try self.readU32(),
            0xa0...0xbf => marker & 0x1f,
            0xd9 => try self.readByte(),
            0xda => try self.readU16(),
            0xdb => try self.readU32(),
            else => error.UnsupportedMsgpack,
        };
    }

    fn readU16(self: *MsgpackReader) !u16 {
        const a = try self.readByte();
        const b = try self.readByte();
        return (@as(u16, a) << 8) | b;
    }

    fn readU32(self: *MsgpackReader) !u32 {
        const a = try self.readByte();
        const b = try self.readByte();
        const d = try self.readByte();
        const e = try self.readByte();
        return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, d) << 8) | e;
    }

    fn readString(self: *MsgpackReader) ![]const u8 {
        const marker = try self.readByte();
        const len = try self.readLen(marker);
        if (self.pos + len > self.data.len) return error.EndOfStream;
        const value = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return value;
    }

    fn readUint(self: *MsgpackReader) !u32 {
        const marker = try self.readByte();
        return switch (marker) {
            0x00...0x7f => marker,
            0xcc => try self.readByte(),
            0xcd => try self.readU16(),
            0xce => try self.readU32(),
            else => error.UnsupportedMsgpack,
        };
    }

    fn skip(self: *MsgpackReader) !void {
        const marker = try self.readByte();
        switch (marker) {
            0x00...0x7f, 0xc0, 0xc2, 0xc3 => {},
            0xcc => _ = try self.readByte(),
            0xcd => _ = try self.readU16(),
            0xce => _ = try self.readU32(),
            0xa0...0xbf, 0xd9, 0xda, 0xdb => {
                const len = try self.readLen(marker);
                if (self.pos + len > self.data.len) return error.EndOfStream;
                self.pos += len;
            },
            0x80...0x8f, 0xde, 0xdf => {
                const len = try self.readLen(marker);
                for (0..len) |_| {
                    try self.skip();
                    try self.skip();
                }
            },
            0x90...0x9f, 0xdc, 0xdd => {
                const len = try self.readLen(marker);
                for (0..len) |_| try self.skip();
            },
            else => return error.UnsupportedMsgpack,
        }
    }
};

pub fn decodeClientMessage(data: []const u8) !ClientMessage {
    var reader = MsgpackReader{ .data = data };
    const marker = try reader.readByte();
    const len = try reader.readLen(marker);
    if (len == 0) return .unknown;

    const opcode_raw = try reader.readUint();
    const opcode = std.meta.intToEnum(ClientOpcode, @as(u8, @intCast(opcode_raw))) catch return .unknown;
    switch (opcode) {
        .input => {
            if (len != 3) return .unknown;
            const terminal_id = try reader.readUint();
            const data_text = try reader.readString();
            return .{ .input = .{ .terminal_id = terminal_id, .data = data_text } };
        },
        .resize => {
            if (len != 4) return .unknown;
            const terminal_id = try reader.readUint();
            const cols: u16 = @intCast(try reader.readUint());
            const rows: u16 = @intCast(try reader.readUint());
            return .{ .resize = .{ .terminal_id = terminal_id, .cols = cols, .rows = rows } };
        },
        .claim_writer => {
            if (len != 2) return .unknown;
            return .{ .claim_writer = .{ .terminal_id = try reader.readUint() } };
        },
        .scroll => {
            if (len != 4) return .unknown;
            const terminal_id = try reader.readUint();
            const rows: u16 = @intCast(try reader.readUint());
            const direction_raw = try reader.readUint();
            const direction = std.meta.intToEnum(ScrollDirection, @as(u8, @intCast(direction_raw))) catch return .unknown;
            return .{ .scroll = .{ .terminal_id = terminal_id, .rows = rows, .direction = direction } };
        },
        .list_terminals => {
            return .list_terminals;
        },
        .create_terminal => {
            if (len != 3) return .unknown;
            const cols: u16 = @intCast(try reader.readUint());
            const rows: u16 = @intCast(try reader.readUint());
            return .{ .create_terminal = .{ .cols = cols, .rows = rows } };
        },
        .close_terminal => {
            if (len != 2) return .unknown;
            return .{ .close_terminal = .{ .terminal_id = try reader.readUint() } };
        },
    }
}

test "decodes compact client protocol messages" {
    const input = [_]u8{ 0x93, 0x01, 0x2a, 0xa1, 'x' };
    const msg = try decodeClientMessage(&input);
    try std.testing.expectEqual(@as(u32, 42), msg.input.terminal_id);
    try std.testing.expectEqualStrings("x", msg.input.data);

    const resize = [_]u8{ 0x94, 0x02, 0x2a, 0xcc, 120, 0x28 };
    const resize_msg = try decodeClientMessage(&resize);
    try std.testing.expectEqual(@as(u32, 42), resize_msg.resize.terminal_id);
    try std.testing.expectEqual(@as(u16, 120), resize_msg.resize.cols);
    try std.testing.expectEqual(@as(u16, 40), resize_msg.resize.rows);

    const claim = [_]u8{ 0x92, 0x03, 0x2a };
    const claim_msg = try decodeClientMessage(&claim);
    try std.testing.expectEqual(@as(u32, 42), claim_msg.claim_writer.terminal_id);

    const scroll = [_]u8{ 0x94, 0x04, 0x2a, 0x03, 0x00 };
    const scroll_msg = try decodeClientMessage(&scroll);
    try std.testing.expectEqual(@as(u32, 42), scroll_msg.scroll.terminal_id);
    try std.testing.expectEqual(@as(u16, 3), scroll_msg.scroll.rows);
    try std.testing.expectEqual(ScrollDirection.up, scroll_msg.scroll.direction);
}

test "cell diff ranges include only changed single cells" {
    const alloc = std.testing.allocator;
    var previous = [_]Cell{
        .{ .char = 'a' },
        .{ .char = 'b' },
        .{ .char = 'c' },
        .{ .char = 'd' },
        .{ .char = 'e' },
        .{ .char = 'f' },
    };
    var current = previous;
    current[1].char = 'B';
    current[4].char = 'E';

    var ranges = try buildChangedRanges(alloc, &previous, &current, 3, 2);
    defer ranges.deinit();

    try std.testing.expectEqual(@as(usize, 2), ranges.items.len);
    try std.testing.expectEqual(CellRange{ .row = 0, .col = 1, .len = 1 }, ranges.items[0]);
    try std.testing.expectEqual(CellRange{ .row = 1, .col = 1, .len = 1 }, ranges.items[1]);
}

test "cell diff ranges group contiguous changed cells" {
    const alloc = std.testing.allocator;
    var previous = [_]Cell{
        .{ .char = 'a' },
        .{ .char = 'b' },
        .{ .char = 'c' },
        .{ .char = 'd' },
        .{ .char = 'e' },
        .{ .char = 'f' },
    };
    var current = previous;
    current[1].char = 'B';
    current[2].char = 'C';
    current[3].flags = 1;

    var ranges = try buildChangedRanges(alloc, &previous, &current, 6, 1);
    defer ranges.deinit();

    try std.testing.expectEqual(@as(usize, 1), ranges.items.len);
    try std.testing.expectEqual(CellRange{ .row = 0, .col = 1, .len = 3 }, ranges.items[0]);
}

test "cell diff ranges split wide changed spans into bounded chunks" {
    const alloc = std.testing.allocator;
    var previous: [MAX_CELL_RANGE_LEN + 5]Cell = undefined;
    var current: [MAX_CELL_RANGE_LEN + 5]Cell = undefined;
    for (&previous, &current) |*prev, *cur| {
        prev.* = .{ .char = 'x' };
        cur.* = .{ .char = ' ' };
    }

    var ranges = try buildChangedRanges(alloc, &previous, &current, previous.len, 1);
    defer ranges.deinit();

    try std.testing.expectEqual(@as(usize, 2), ranges.items.len);
    try std.testing.expectEqual(CellRange{ .row = 0, .col = 0, .len = MAX_CELL_RANGE_LEN }, ranges.items[0]);
    try std.testing.expectEqual(CellRange{ .row = 0, .col = MAX_CELL_RANGE_LEN, .len = 5 }, ranges.items[1]);
}

test "cell diff ranges include style-only changes" {
    const alloc = std.testing.allocator;
    var previous = [_]Cell{.{ .char = 'x', .fg_rgb = 0xff0000 }};
    var current = previous;
    current[0].fg_rgb = 0x00ff00;

    var ranges = try buildChangedRanges(alloc, &previous, &current, 1, 1);
    defer ranges.deinit();

    try std.testing.expectEqual(@as(usize, 1), ranges.items.len);
    try std.testing.expectEqual(CellRange{ .row = 0, .col = 0, .len = 1 }, ranges.items[0]);
}

test "row range protocol encodes row column and cells" {
    const alloc = std.testing.allocator;
    var cells = [_]Cell{
        .{ .char = 'a' },
        .{ .char = 'B', .flags = 1 },
        .{ .char = 'C', .fg_rgb = 0x112233 },
        .{ .char = 'd' },
    };
    const snap: Snapshot = .{
        .cols = 4,
        .rows = 1,
        .cursor_row = 0,
        .cursor_col = 3,
        .cursor_visible = true,
        .mouse_reporting = false,
        .cells = &cells,
    };
    const ranges = [_]CellRange{.{ .row = 0, .col = 1, .len = 2 }};

    const payload = try encodeRows(alloc, 7, snap, &ranges);
    defer alloc.free(payload);

    const expected = [_]u8{
        0x94, 0x02, 0x07, 0x93, 0x00, 0x03, 0xc3, 0x91,
        0x93, 0x00, 0x01, 0x92,
        0x94, 'B', 0xcd, 0x01, 0x00, 0xcd, 0x01, 0x00, 0x01,
        0x96, 'C', 0xcd, 0x01, 0x00, 0xcd, 0x01, 0x00, 0x00, 0xce, 0x00, 0x11, 0x22, 0x33, 0xc0,
    };
    try std.testing.expectEqualSlices(u8, &expected, payload);
}

test "row range protocol can carry cursor-only updates" {
    const alloc = std.testing.allocator;
    var cells = [_]Cell{.{ .char = ' ' }};
    const snap: Snapshot = .{
        .cols = 1,
        .rows = 1,
        .cursor_row = 0,
        .cursor_col = 1,
        .cursor_visible = true,
        .mouse_reporting = false,
        .cells = &cells,
    };

    const payload = try encodeRows(alloc, 3, snap, &.{});
    defer alloc.free(payload);

    const expected = [_]u8{
        0x94, 0x02, 0x03, 0x93, 0x00, 0x01, 0xc3, 0x90,
    };
    try std.testing.expectEqualSlices(u8, &expected, payload);
}
