const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const StreamAction = vt.StreamAction;
const embedded_assets = @import("embedded_assets.zig");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("netinet/in.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    if (builtin.os.tag == .linux) {
        @cInclude("pty.h");
    } else {
        @cInclude("util.h");
    }
});

const DEFAULT_COLOR: u16 = 256;
const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;
const MAX_CLIENTS: usize = 64;
const MAX_TERMINALS: usize = 16;
const MAX_TITLE_BYTES: usize = 256;
const MAX_PWD_BYTES: usize = 512;
const SNAPSHOT_COALESCE_MS: i64 = 16;
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const DEFAULT_TERMINAL_ID: u32 = 0;

const ClientOpcode = enum(u8) {
    input = 1,
    resize = 2,
    claim_writer = 3,
    scroll = 4,
    list_terminals = 5,
    create_terminal = 6,
    close_terminal = 7,
};

const ServerOpcode = enum(u8) {
    snapshot = 1,
    rows = 2,
    role = 3,
    exit = 4,
    terminals = 5,
    terminal_created = 6,
    terminal_closed = 7,
};

const WireRole = enum(u8) {
    reader = 0,
    writer = 1,
};

const ScrollDirection = enum(u8) {
    up = 0,
    down = 1,
};

const TerminalContentFormat = enum {
    html,
    text,
};

const Cell = struct {
    char: u32,
    fg: u16 = DEFAULT_COLOR,
    bg: u16 = DEFAULT_COLOR,
    flags: u8 = 0,
    fg_rgb: ?u24 = null,
    bg_rgb: ?u24 = null,
};

const Snapshot = struct {
    cols: u16,
    rows: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    mouse_reporting: bool,
    cells: []Cell,
};

const Role = enum {
    writer,
    reader,

    fn wire(self: Role) WireRole {
        return switch (self) {
            .writer => .writer,
            .reader => .reader,
        };
    }
};

const ClientMessage = union(enum) {
    input: struct { terminal_id: u32, data: []const u8 },
    resize: struct { terminal_id: u32, cols: u16, rows: u16 },
    scroll: struct { terminal_id: u32, rows: u16, direction: ScrollDirection },
    claim_writer: struct { terminal_id: u32 },
    list_terminals,
    create_terminal: struct { cols: u16, rows: u16 },
    close_terminal: struct { terminal_id: u32 },
    unknown,
};

const Client = struct {
    fd: c_int,
    role: Role,
    terminal_id: u32,
};

const TitleStream = vt.Stream(TitleStreamHandler);

const TitleStreamHandler = struct {
    session: *TerminalSession,

    pub fn deinit(self: *TitleStreamHandler) void {
        _ = self;
    }

    pub fn vt(
        self: *TitleStreamHandler,
        comptime action: StreamAction.Tag,
        value: StreamAction.Value(action),
    ) !void {
        if (action == .window_title) {
            if (self.session.setTitle(value.title)) self.session.metadata_changed = true;
        } else if (action == .report_pwd) {
            if (self.session.setPwd(value.url)) self.session.metadata_changed = true;
        }

        var readonly = self.session.terminal.vtHandler();
        try readonly.vt(action, value);
    }
};

const TerminalSession = struct {
    id: u32,
    pty_fd: c_int,
    terminal: vt.Terminal,
    stream: TitleStream,
    render: vt.RenderState,
    clients: std.array_list.Managed(Client),
    title: [MAX_TITLE_BYTES]u8 = undefined,
    title_len: usize = 0,
    pwd: [MAX_PWD_BYTES]u8 = undefined,
    pwd_len: usize = 0,
    metadata_changed: bool = false,
    pending_resize: ?struct { cols: u16, rows: u16 } = null,
    pending_snapshot: bool = false,
    last_pty_output_ms: i64 = 0,

    fn create(alloc: std.mem.Allocator, id: u32, cols: u16, rows: u16) !*TerminalSession {
        const session = try alloc.create(TerminalSession);
        errdefer alloc.destroy(session);
        session.* = undefined;
        session.id = id;
        session.pty_fd = -1;
        session.terminal = try .init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 10 * 1024 * 1024,
        });
        errdefer session.terminal.deinit(alloc);
        session.stream = TitleStream.initAlloc(alloc, .{ .session = session });
        errdefer session.stream.deinit();
        session.render = .empty;
        session.clients = std.array_list.Managed(Client).init(alloc);
        session.title_len = 0;
        session.pwd_len = 0;
        session.metadata_changed = false;
        session.pending_resize = null;
        session.pending_snapshot = false;
        session.last_pty_output_ms = 0;
        session.pty_fd = try spawnPty(cols, rows);
        return session;
    }

    fn deinit(self: *TerminalSession, alloc: std.mem.Allocator) void {
        for (self.clients.items) |client| _ = c.close(client.fd);
        self.clients.deinit();
        self.stream.deinit();
        self.render.deinit(alloc);
        self.terminal.deinit(alloc);
        if (self.pty_fd >= 0) _ = c.close(self.pty_fd);
        alloc.destroy(self);
    }

    fn titleSlice(self: *const TerminalSession) ?[]const u8 {
        if (self.title_len == 0) return null;
        return self.title[0..self.title_len];
    }

    fn pwdSlice(self: *const TerminalSession) ?[]const u8 {
        if (self.pwd_len == 0) return null;
        return self.pwd[0..self.pwd_len];
    }

    fn setTitle(self: *TerminalSession, title: []const u8) bool {
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        const len = @min(trimmed.len, self.title.len);
        if (self.title_len == len and std.mem.eql(u8, self.title[0..len], trimmed[0..len])) return false;
        if (len > 0) @memcpy(self.title[0..len], trimmed[0..len]);
        self.title_len = len;
        return true;
    }

    fn setPwd(self: *TerminalSession, url: []const u8) bool {
        const path = pwdPathFromUrl(url);
        const len = @min(path.len, self.pwd.len);
        if (self.pwd_len == len and std.mem.eql(u8, self.pwd[0..len], path[0..len])) return false;
        if (len > 0) @memcpy(self.pwd[0..len], path[0..len]);
        self.pwd_len = len;
        return true;
    }
};

fn packRgb(rgb: vt.color.RGB) u24 {
    return (@as(u24, rgb.r) << 16) | (@as(u24, rgb.g) << 8) | @as(u24, rgb.b);
}

fn packFlags(style: vt.Style) u8 {
    var flags: u8 = 0;
    if (style.flags.bold) flags |= 0x01;
    if (style.flags.faint) flags |= 0x02;
    if (style.flags.italic) flags |= 0x04;
    if (style.flags.underline != .none) flags |= 0x08;
    if (style.flags.blink) flags |= 0x10;
    if (style.flags.inverse) flags |= 0x20;
    if (style.flags.invisible) flags |= 0x40;
    if (style.flags.strikethrough) flags |= 0x80;
    return flags;
}

fn resolveRgb(color: vt.Style.Color, palette: *const vt.color.Palette) ?u24 {
    return switch (color) {
        .none => null,
        .palette => |idx| packRgb(palette[idx]),
        .rgb => |rgb| packRgb(rgb),
    };
}

fn cellBackgroundRgb(raw: vt.Cell, palette: *const vt.color.Palette) ?u24 {
    return switch (raw.content_tag) {
        .bg_color_palette => packRgb(palette[raw.content.color_palette]),
        .bg_color_rgb => packRgb(.{
            .r = raw.content.color_rgb.r,
            .g = raw.content.color_rgb.g,
            .b = raw.content.color_rgb.b,
        }),
        else => null,
    };
}

fn contentCodepoint(raw: vt.Cell) u32 {
    return switch (raw.content_tag) {
        .codepoint, .codepoint_grapheme => raw.content.codepoint,
        else => 0,
    };
}

fn snapshot(alloc: std.mem.Allocator, terminal: *vt.Terminal, render: *vt.RenderState) !Snapshot {
    try render.update(alloc, terminal);

    const cols = render.cols;
    const rows = render.rows;
    const palette = &render.colors.palette;
    const cells = try alloc.alloc(Cell, @as(usize, cols) * @as(usize, rows));
    errdefer alloc.free(cells);

    const row_cells = render.row_data.items(.cells);
    for (0..rows) |y| {
        const row = if (y < row_cells.len) row_cells[y] else null;
        for (0..cols) |x| {
            const out = &cells[@as(usize, y) * @as(usize, cols) + @as(usize, x)];
            out.* = .{ .char = 32 };
            const cell_list = row orelse continue;
            const raw_cells = cell_list.items(.raw);
            if (x >= raw_cells.len) continue;

            const raw = raw_cells[x];
            const has_style = raw.style_id > 0;
            const style: vt.Style = if (has_style) cell_list.items(.style)[x] else .{};
            const bg_rgb = cellBackgroundRgb(raw, palette) orelse
                if (has_style) resolveRgb(style.bg_color, palette) else null;
            out.* = .{
                .char = contentCodepoint(raw),
                .flags = packFlags(style),
                .fg_rgb = if (has_style) resolveRgb(style.fg_color, palette) else null,
                .bg_rgb = bg_rgb,
            };
        }
    }

    const cursor = render.cursor.viewport;
    return .{
        .cols = cols,
        .rows = rows,
        .cursor_row = if (cursor) |cur| cur.y else 0,
        .cursor_col = if (cursor) |cur| cur.x else 0,
        .cursor_visible = render.cursor.visible and cursor != null,
        .mouse_reporting = terminal.modes.get(.mouse_event_x10) or
            terminal.modes.get(.mouse_event_normal) or
            terminal.modes.get(.mouse_event_button) or
            terminal.modes.get(.mouse_event_any),
        .cells = cells,
    };
}

const MsgpackWriter = struct {
    buf: std.array_list.Managed(u8),

    fn init(alloc: std.mem.Allocator) MsgpackWriter {
        return .{ .buf = std.array_list.Managed(u8).init(alloc) };
    }

    fn deinit(self: *MsgpackWriter) void {
        self.buf.deinit();
    }

    fn bytes(self: *const MsgpackWriter) []const u8 {
        return self.buf.items;
    }

    fn byte(self: *MsgpackWriter, value: u8) !void {
        try self.buf.append(value);
    }

    fn str(self: *MsgpackWriter, value: []const u8) !void {
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

    fn map(self: *MsgpackWriter, len: u16) !void {
        if (len <= 15) {
            try self.byte(0x80 | @as(u8, @intCast(len)));
        } else {
            try self.byte(0xde);
            try self.u16be(len);
        }
    }

    fn array(self: *MsgpackWriter, len: u32) !void {
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

    fn boolValue(self: *MsgpackWriter, value: bool) !void {
        try self.byte(if (value) 0xc3 else 0xc2);
    }

    fn nilValue(self: *MsgpackWriter) !void {
        try self.byte(0xc0);
    }

    fn uint(self: *MsgpackWriter, value: u32) !void {
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

fn encodeSnapshot(alloc: std.mem.Allocator, terminal_id: u32, snap: Snapshot, role: Role) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();

    try writer.array(10);
    try writer.uint(@intFromEnum(ServerOpcode.snapshot));
    try writer.uint(terminal_id);
    try writer.uint(snap.cols);
    try writer.uint(snap.rows);
    try writer.uint(@intFromEnum(role.wire()));
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

fn encodeRole(alloc: std.mem.Allocator, terminal_id: u32, role: Role) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();
    try writer.array(3);
    try writer.uint(@intFromEnum(ServerOpcode.role));
    try writer.uint(terminal_id);
    try writer.uint(@intFromEnum(role.wire()));
    return writer.buf.toOwnedSlice();
}

fn encodeTerminals(alloc: std.mem.Allocator, terminals: *std.array_list.Managed(*TerminalSession)) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();
    try writer.array(2);
    try writer.uint(@intFromEnum(ServerOpcode.terminals));
    try writer.array(@intCast(terminals.items.len));
    for (terminals.items) |session| {
        var writer_connected = false;
        for (session.clients.items) |client| {
            if (client.role == .writer) {
                writer_connected = true;
                break;
            }
        }
        try writer.array(7);
        try writer.uint(session.id);
        if (session.titleSlice()) |title| {
            try writer.str(title);
        } else {
            try writer.nilValue();
        }
        if (session.pwdSlice()) |pwd| {
            try writer.str(pwd);
        } else {
            try writer.nilValue();
        }
        try writer.uint(session.terminal.cols);
        try writer.uint(session.terminal.rows);
        try writer.uint(@intFromEnum(WireRole.reader));
        try writer.boolValue(writer_connected);
    }
    return writer.buf.toOwnedSlice();
}

fn encodeTerminalCreated(alloc: std.mem.Allocator, session: *TerminalSession) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();
    try writer.array(2);
    try writer.uint(@intFromEnum(ServerOpcode.terminal_created));
    try writer.array(7);
    try writer.uint(session.id);
    if (session.titleSlice()) |title| {
        try writer.str(title);
    } else {
        try writer.nilValue();
    }
    if (session.pwdSlice()) |pwd| {
        try writer.str(pwd);
    } else {
        try writer.nilValue();
    }
    try writer.uint(session.terminal.cols);
    try writer.uint(session.terminal.rows);
    try writer.uint(@intFromEnum(WireRole.reader));
    try writer.boolValue(false);
    return writer.buf.toOwnedSlice();
}

fn appendCodepoint(buf: *std.array_list.Managed(u8), codepoint: u32) !void {
    const scalar = if (codepoint == 0) 32 else codepoint;
    if (scalar > 0x10ffff) {
        try buf.appendSlice("\xef\xbf\xbd");
        return;
    }
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@as(u21, @intCast(scalar)), &encoded) catch {
        try buf.appendSlice("\xef\xbf\xbd");
        return;
    };
    try buf.appendSlice(encoded[0..len]);
}

fn appendHtmlEscapedCodepoint(buf: *std.array_list.Managed(u8), codepoint: u32) !void {
    switch (if (codepoint == 0) 32 else codepoint) {
        '&' => try buf.appendSlice("&amp;"),
        '<' => try buf.appendSlice("&lt;"),
        '>' => try buf.appendSlice("&gt;"),
        '"' => try buf.appendSlice("&quot;"),
        '\'' => try buf.appendSlice("&#39;"),
        else => |cp| try appendCodepoint(buf, cp),
    }
}

fn appendJsonString(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    try buf.append('"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try buf.appendSlice("\\\\"),
            '"' => try buf.appendSlice("\\\""),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            0...8, 11...12, 14...0x1f => try buf.writer().print("\\u{x:0>4}", .{byte}),
            else => try buf.append(byte),
        }
    }
    try buf.append('"');
}

fn appendHexColor(buf: *std.array_list.Managed(u8), rgb: u24) !void {
    try buf.writer().print("#{x:0>6}", .{rgb});
}

fn appendCellStyle(buf: *std.array_list.Managed(u8), cell: Cell) !bool {
    const has_style = cell.fg_rgb != null or cell.bg_rgb != null or cell.flags != 0;
    if (!has_style) return false;

    try buf.appendSlice("<span style=\"");
    if (cell.fg_rgb) |rgb| {
        try buf.appendSlice("color:");
        try appendHexColor(buf, rgb);
        try buf.appendSlice(";");
    }
    if (cell.bg_rgb) |rgb| {
        try buf.appendSlice("background-color:");
        try appendHexColor(buf, rgb);
        try buf.appendSlice(";");
    }
    if ((cell.flags & 0x01) != 0) try buf.appendSlice("font-weight:700;");
    if ((cell.flags & 0x02) != 0) try buf.appendSlice("opacity:.7;");
    if ((cell.flags & 0x04) != 0) try buf.appendSlice("font-style:italic;");
    if ((cell.flags & 0x08) != 0) try buf.appendSlice("text-decoration:underline;");
    if ((cell.flags & 0x80) != 0) try buf.appendSlice("text-decoration:line-through;");
    try buf.appendSlice("\">");
    return true;
}

fn snapshotText(alloc: std.mem.Allocator, snap: Snapshot) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();

    for (0..snap.rows) |row| {
        const start = row * @as(usize, snap.cols);
        var end = start + snap.cols;
        while (end > start) {
            const cell = snap.cells[end - 1];
            const char = if (cell.char == 0) 32 else cell.char;
            if (char != 32) break;
            end -= 1;
        }
        for (snap.cells[start..end]) |cell| try appendCodepoint(&out, cell.char);
        if (row + 1 < snap.rows) try out.append('\n');
    }

    return out.toOwnedSlice();
}

fn snapshotHtml(alloc: std.mem.Allocator, terminal_id: u32, snap: Snapshot) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();

    try out.writer().print(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>ghostd terminal {d}</title><style>body{{margin:0;background:#1e1e1e;color:#d4d4d4}}pre{{margin:0;padding:12px;font:14px/17px Menlo,Consolas,monospace;white-space:pre}}</style></head><body><pre>",
        .{terminal_id},
    );
    for (0..snap.rows) |row| {
        const start = row * @as(usize, snap.cols);
        var end = start + snap.cols;
        while (end > start) {
            const cell = snap.cells[end - 1];
            const char = if (cell.char == 0) 32 else cell.char;
            if (char != 32 or cell.bg_rgb != null) break;
            end -= 1;
        }
        for (snap.cells[start..end]) |cell| {
            const styled = try appendCellStyle(&out, cell);
            try appendHtmlEscapedCodepoint(&out, cell.char);
            if (styled) try out.appendSlice("</span>");
        }
        if (row + 1 < snap.rows) try out.append('\n');
    }
    try out.appendSlice("</pre></body></html>");

    return out.toOwnedSlice();
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

fn decodeClientMessage(data: []const u8) !ClientMessage {
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
            const input = try reader.readString();
            return .{ .input = .{ .terminal_id = terminal_id, .data = input } };
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
            const direction_raw: u8 = @intCast(try reader.readUint());
            const direction = std.meta.intToEnum(ScrollDirection, direction_raw) catch return .unknown;
            return .{ .scroll = .{ .terminal_id = terminal_id, .rows = rows, .direction = direction } };
        },
        .list_terminals => {
            if (len != 1) return .unknown;
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

fn parsePort(args: []const []const u8) u16 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            return std.fmt.parseInt(u16, args[i + 1], 10) catch 7341;
        }
        if (std.mem.startsWith(u8, args[i], "--port=")) {
            return std.fmt.parseInt(u16, args[i]["--port=".len..], 10) catch 7341;
        }
    }
    if (std.posix.getenv("PORT")) |port| return std.fmt.parseInt(u16, port, 10) catch 7341;
    return 7341;
}

fn parseHost(args: []const []const u8) []const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            return args[i + 1];
        }
        if (std.mem.startsWith(u8, args[i], "--host=")) {
            return args[i]["--host=".len..];
        }
    }
    if (std.posix.getenv("HOST")) |host| return host;
    return "127.0.0.1";
}

fn wantsHelp(args: []const []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn printUsage() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        \\Usage: ghostd [--host HOST] [--port PORT]
        \\
        \\Options:
        \\  -h, --help     Show this help message.
        \\  --host HOST    Listen on HOST (default: 127.0.0.1, or HOST env var).
        \\  --port PORT    Listen on PORT (default: 7341, or PORT env var).
        \\
    );
    try stdout.flush();
}

fn setNonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.FcntlFailed;
}

fn writeAllFd(fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const written = c.write(fd, data.ptr + off, data.len - off);
        if (written < 0) {
            if (std.posix.errno(-1) == .INTR) continue;
            if (std.posix.errno(-1) == .AGAIN) {
                var pfd: c.struct_pollfd = .{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
                const ready = c.poll(&pfd, 1, 1000);
                if (ready > 0) continue;
                return error.WriteTimedOut;
            }
            return error.WriteFailed;
        }
        if (written == 0) return error.WriteFailed;
        off += @intCast(written);
    }
}

fn createListenSocket(host: []const u8, port: u16) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var yes: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    if (std.mem.eql(u8, host, "0.0.0.0")) {
        addr.sin_addr.s_addr = c.htonl(c.INADDR_ANY);
    } else if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost")) {
        addr.sin_addr.s_addr = c.htonl(c.INADDR_LOOPBACK);
    } else {
        return error.UnsupportedHost;
    }
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0) return error.BindFailed;
    if (c.listen(fd, 32) < 0) return error.ListenFailed;
    try setNonblocking(fd);
    return fd;
}

fn spawnPty(cols: u16, rows: u16) !c_int {
    var master: c_int = -1;
    var winsize: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    winsize.ws_col = cols;
    winsize.ws_row = rows;

    const pid = c.forkpty(&master, null, null, &winsize);
    if (pid < 0) return error.ForkptyFailed;
    if (pid == 0) {
        _ = c.unsetenv("NO_COLOR");
        _ = c.unsetenv("NODE_DISABLE_COLORS");
        _ = c.setenv("TERM", "xterm-256color", 1);
        _ = c.setenv("COLORTERM", "truecolor", 1);
        _ = c.setenv("CLICOLOR", "1", 1);
        _ = c.setenv("FORCE_COLOR", "1", 1);
        const shell: [*c]const u8 = if (c.getenv("SHELL")) |shell_env| shell_env else "/bin/zsh";
        _ = c.execlp(shell, shell, @as(?*anyopaque, null));
        c._exit(127);
    }
    try setNonblocking(master);
    return master;
}

fn resizePty(fd: c_int, cols: u16, rows: u16) !void {
    var winsize: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    winsize.ws_col = cols;
    winsize.ws_row = rows;
    if (c.ioctl(fd, c.TIOCSWINSZ, &winsize) < 0) return error.ResizeFailed;
}

fn findHeader(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn websocketAccept(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    const joined = try std.mem.concat(alloc, u8, &.{ key, WS_GUID });
    defer alloc.free(joined);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(joined, &digest, .{});
    const out_len = std.base64.standard.Encoder.calcSize(digest.len);
    const out = try alloc.alloc(u8, out_len);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

fn sendHttpContent(fd: c_int, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len });
    try writeAllFd(fd, text);
    try writeAllFd(fd, body);
}

fn sendHttp(fd: c_int, status: []const u8, body: []const u8) !void {
    try sendHttpContent(fd, status, "text/plain; charset=utf-8", body);
}

fn requestPath(request: []const u8) []const u8 {
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next();
    const raw = parts.next() orelse "/";
    const query = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    return raw[0..query];
}

fn acceptsHtml(request: []const u8) bool {
    const accept = findHeader(request, "Accept") orelse return false;
    if (std.mem.indexOf(u8, accept, "text/html") == null) return false;
    const text_pos = std.mem.indexOf(u8, accept, "text/plain") orelse return true;
    const html_pos = std.mem.indexOf(u8, accept, "text/html") orelse return false;
    return html_pos < text_pos;
}

fn terminalContentFormat(request: []const u8, path: []const u8) TerminalContentFormat {
    if (std.mem.endsWith(u8, path, ".html")) return .html;
    if (std.mem.endsWith(u8, path, ".txt")) return .text;
    return if (acceptsHtml(request)) .html else .text;
}

fn terminalIdFromApiPath(path: []const u8) ?u32 {
    const prefix = "/api/terminals/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var id_part = path[prefix.len..];
    if (std.mem.endsWith(u8, id_part, ".html")) id_part = id_part[0 .. id_part.len - ".html".len];
    if (std.mem.endsWith(u8, id_part, ".txt")) id_part = id_part[0 .. id_part.len - ".txt".len];
    if (id_part.len == 0) return null;
    return std.fmt.parseInt(u32, id_part, 10) catch null;
}

fn terminalIdFromWebsocketPath(path: []const u8) ?u32 {
    const prefix = "/terminal/";
    const suffix = ".ws";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (!std.mem.endsWith(u8, path, suffix)) return null;
    const id_part = path[prefix.len .. path.len - suffix.len];
    if (id_part.len == 0) return null;
    return std.fmt.parseInt(u32, id_part, 10) catch null;
}

fn pwdPathFromUrl(url: []const u8) []const u8 {
    const file_prefix = "file://";
    const kitty_prefix = "kitty-shell-cwd://";
    const raw = if (std.mem.startsWith(u8, url, file_prefix))
        url[file_prefix.len..]
    else if (std.mem.startsWith(u8, url, kitty_prefix))
        url[kitty_prefix.len..]
    else
        url;
    if (raw.len == 0) return raw;
    if (raw[0] == '/') return raw;
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return raw;
    return raw[slash..];
}

fn sendTerminalsJson(alloc: std.mem.Allocator, fd: c_int, terminals: *std.array_list.Managed(*TerminalSession)) !void {
    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();
    try body.appendSlice("{\"terminals\":[");
    for (terminals.items, 0..) |session, index| {
        var writer_connected = false;
        for (session.clients.items) |client| {
            if (client.role == .writer) {
                writer_connected = true;
                break;
            }
        }
        if (index > 0) try body.append(',');
        try body.writer().print(
            "{{\"id\":{d},\"title\":",
            .{session.id},
        );
        if (session.titleSlice()) |title| {
            try appendJsonString(&body, title);
        } else {
            try body.appendSlice("null");
        }
        try body.appendSlice(",\"pwd\":");
        if (session.pwdSlice()) |pwd| {
            try appendJsonString(&body, pwd);
        } else {
            try body.appendSlice("null");
        }
        try body.writer().print(
            ",\"cols\":{d},\"rows\":{d},\"writerConnected\":{s}}}",
            .{ session.terminal.cols, session.terminal.rows, if (writer_connected) "true" else "false" },
        );
    }
    try body.appendSlice("]}");
    try sendHttpContent(fd, "200 OK", "application/json; charset=utf-8", body.items);
}

fn sendTerminalContent(alloc: std.mem.Allocator, fd: c_int, request: []const u8, session: *TerminalSession) !void {
    const path = requestPath(request);
    const format = terminalContentFormat(request, path);
    const snap = try snapshot(alloc, &session.terminal, &session.render);
    defer alloc.free(snap.cells);

    const body = switch (format) {
        .html => try snapshotHtml(alloc, session.id, snap),
        .text => try snapshotText(alloc, snap),
    };
    defer alloc.free(body);

    const content_type = switch (format) {
        .html => "text/html; charset=utf-8",
        .text => "text/plain; charset=utf-8",
    };
    try sendHttpContent(fd, "200 OK", content_type, body);
}

fn sendApi(alloc: std.mem.Allocator, fd: c_int, request: []const u8, terminals: *std.array_list.Managed(*TerminalSession)) !bool {
    const path = requestPath(request);
    if (std.mem.eql(u8, path, "/api/terminals")) {
        try sendTerminalsJson(alloc, fd, terminals);
        return true;
    }
    if (terminalIdFromApiPath(path)) |terminal_id| {
        const session = findSession(terminals, terminal_id) orelse {
            try sendHttp(fd, "404 Not Found", "terminal not found\n");
            return true;
        };
        try sendTerminalContent(alloc, fd, request, session);
        return true;
    }
    if (std.mem.startsWith(u8, path, "/api/")) {
        try sendHttp(fd, "404 Not Found", "not found\n");
        return true;
    }
    return false;
}

fn sendStatic(fd: c_int, request: []const u8) !void {
    const path = requestPath(request);
    if (std.mem.indexOf(u8, path, "..") != null) {
        try sendHttp(fd, "400 Bad Request", "bad path\n");
        return;
    }

    const asset = for (embedded_assets.assets) |asset| {
        if (std.mem.eql(u8, asset.path, path)) break asset;
    } else {
        try sendHttp(fd, "404 Not Found", "not found\n");
        return;
    };

    var header: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ asset.content_type, asset.body.len });
    try writeAllFd(fd, text);
    try writeAllFd(fd, asset.body);
}

fn findSession(terminals: *std.array_list.Managed(*TerminalSession), terminal_id: u32) ?*TerminalSession {
    for (terminals.items) |session| {
        if (session.id == terminal_id) return session;
    }
    return null;
}

fn sendTerminals(alloc: std.mem.Allocator, fd: c_int, terminals: *std.array_list.Managed(*TerminalSession)) !void {
    const payload = try encodeTerminals(alloc, terminals);
    defer alloc.free(payload);
    try sendWebsocket(fd, payload);
}

fn broadcastTerminals(alloc: std.mem.Allocator, terminals: *std.array_list.Managed(*TerminalSession)) void {
    const payload = encodeTerminals(alloc, terminals) catch return;
    defer alloc.free(payload);
    for (terminals.items) |session| {
        var i: usize = 0;
        while (i < session.clients.items.len) {
            sendWebsocket(session.clients.items[i].fd, payload) catch {
                closeClient(session, i);
                continue;
            };
            i += 1;
        }
    }
}

fn acceptClient(alloc: std.mem.Allocator, listen_fd: c_int, terminals: *std.array_list.Managed(*TerminalSession)) !void {
    const fd = c.accept(listen_fd, null, null);
    if (fd < 0) return;
    errdefer _ = c.close(fd);
    try setNonblocking(fd);

    var timeout: c.struct_timeval = .{ .tv_sec = 1, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));

    var request_buf: [8192]u8 = undefined;
    var request_poll: c.struct_pollfd = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&request_poll, 1, 1000) <= 0) return;
    const n = c.read(fd, request_buf[0..].ptr, request_buf.len);
    if (n <= 0) return;
    const request = request_buf[0..@intCast(n)];
    const key = findHeader(request, "Sec-WebSocket-Key") orelse {
        if (try sendApi(alloc, fd, request, terminals)) return;
        try sendStatic(fd, request);
        return;
    };
    const terminal_id = terminalIdFromWebsocketPath(requestPath(request)) orelse {
        try sendHttp(fd, "404 Not Found", "websocket terminal not found\n");
        return;
    };
    const session = findSession(terminals, terminal_id) orelse {
        try sendHttp(fd, "404 Not Found", "terminal not found\n");
        return;
    };

    const accept = try websocketAccept(alloc, key);
    defer alloc.free(accept);
    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
    try writeAllFd(fd, response);

    const role: Role = if (session.clients.items.len == 0) .writer else .reader;
    try session.clients.append(.{ .fd = fd, .role = role, .terminal_id = session.id });
    const client_index = session.clients.items.len - 1;

    const snap = try snapshot(alloc, &session.terminal, &session.render);
    defer alloc.free(snap.cells);
    const payload = try encodeSnapshot(alloc, session.id, snap, role);
    defer alloc.free(payload);
    sendWebsocket(fd, payload) catch {
        closeClient(session, client_index);
        return;
    };
    sendTerminals(alloc, fd, terminals) catch {};
}

fn sendWebsocket(fd: c_int, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    header[0] = 0x82;
    var header_len: usize = 0;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
        header_len = 2;
    } else if (payload.len <= 0xffff) {
        header[1] = 126;
        header[2] = @intCast((payload.len >> 8) & 0xff);
        header[3] = @intCast(payload.len & 0xff);
        header_len = 4;
    } else {
        header[1] = 127;
        const len64: u64 = @intCast(payload.len);
        for (0..8) |i| header[2 + i] = @intCast((len64 >> @intCast((7 - i) * 8)) & 0xff);
        header_len = 10;
    }
    try writeAllFd(fd, header[0..header_len]);
    try writeAllFd(fd, payload);
}

fn readWebsocketFrame(alloc: std.mem.Allocator, fd: c_int) !?[]u8 {
    var header: [2]u8 = undefined;
    const got = c.read(fd, &header, 2);
    if (got == 0) return error.Closed;
    if (got < 0) {
        if (std.posix.errno(-1) == .AGAIN) return null;
        return error.ReadFailed;
    }
    if (got != 2) return error.ReadFailed;
    const opcode = header[0] & 0x0f;
    if (opcode == 0x8) return error.Closed;
    var len: usize = header[1] & 0x7f;
    const masked = (header[1] & 0x80) != 0;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        if (c.read(fd, &ext, 2) != 2) return error.ReadFailed;
        len = (@as(usize, ext[0]) << 8) | ext[1];
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        if (c.read(fd, &ext, 8) != 8) return error.ReadFailed;
        len = 0;
        for (ext) |b| len = (len << 8) | b;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked and c.read(fd, &mask, 4) != 4) return error.ReadFailed;
    const payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);
    var off: usize = 0;
    while (off < len) {
        const n = c.read(fd, payload.ptr + off, len - off);
        if (n <= 0) return error.ReadFailed;
        off += @intCast(n);
    }
    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % 4];
        }
    }
    return payload;
}

fn closeClient(session: *TerminalSession, index: usize) void {
    const was_writer = session.clients.items[index].role == .writer;
    _ = c.close(session.clients.items[index].fd);
    _ = session.clients.swapRemove(index);
    if (was_writer and session.clients.items.len > 0) session.clients.items[0].role = .writer;
}

fn broadcastSnapshot(alloc: std.mem.Allocator, session: *TerminalSession) !void {
    const snap = try snapshot(alloc, &session.terminal, &session.render);
    defer alloc.free(snap.cells);
    var i: usize = 0;
    while (i < session.clients.items.len) {
        const payload = try encodeSnapshot(alloc, session.id, snap, session.clients.items[i].role);
        defer alloc.free(payload);
        sendWebsocket(session.clients.items[i].fd, payload) catch {
            closeClient(session, i);
            continue;
        };
        i += 1;
    }
}

fn broadcastRoles(alloc: std.mem.Allocator, session: *TerminalSession) void {
    var i: usize = 0;
    while (i < session.clients.items.len) {
        const payload = encodeRole(alloc, session.id, session.clients.items[i].role) catch return;
        defer alloc.free(payload);
        sendWebsocket(session.clients.items[i].fd, payload) catch {
            closeClient(session, i);
            continue;
        };
        i += 1;
    }
}

fn claimWriter(session: *TerminalSession, index: usize) void {
    if (index >= session.clients.items.len) return;
    for (session.clients.items) |*client| client.role = .reader;
    session.clients.items[index].role = .writer;
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (wantsHelp(args)) {
        try printUsage();
        return;
    }
    const port = parsePort(args);
    const host = parseHost(args);

    const listen_fd = try createListenSocket(host, port);
    defer _ = c.close(listen_fd);

    var terminals = std.array_list.Managed(*TerminalSession).init(alloc);
    defer {
        for (terminals.items) |session| session.deinit(alloc);
        terminals.deinit();
    }
    try terminals.append(try TerminalSession.create(alloc, DEFAULT_TERMINAL_ID, DEFAULT_COLS, DEFAULT_ROWS));
    var next_terminal_id: u32 = 1;

    std.debug.print("ghostd native listening on http://{s}:{d}\n", .{ host, port });

    var pty_buf: [8192]u8 = undefined;
    while (true) {
        var pollfds: [1 + MAX_TERMINALS + MAX_CLIENTS]c.struct_pollfd = undefined;
        var polled_sessions: [MAX_TERMINALS]*TerminalSession = undefined;
        var polled_client_sessions: [MAX_CLIENTS]*TerminalSession = undefined;
        var polled_client_indexes: [MAX_CLIENTS]usize = undefined;
        var session_count: usize = 0;
        var client_count: usize = 0;

        pollfds[0] = .{ .fd = listen_fd, .events = c.POLLIN, .revents = 0 };
        var poll_index: usize = 1;
        for (terminals.items) |session| {
            if (session_count >= MAX_TERMINALS) break;
            polled_sessions[session_count] = session;
            session_count += 1;
            pollfds[poll_index] = .{ .fd = session.pty_fd, .events = c.POLLIN, .revents = 0 };
            poll_index += 1;
        }
        for (terminals.items) |session| {
            for (session.clients.items, 0..) |client, client_index| {
                if (client_count >= MAX_CLIENTS) break;
                polled_client_sessions[client_count] = session;
                polled_client_indexes[client_count] = client_index;
                client_count += 1;
                pollfds[poll_index] = .{ .fd = client.fd, .events = c.POLLIN, .revents = 0 };
                poll_index += 1;
            }
        }

        var poll_timeout: c_int = -1;
        const now = std.time.milliTimestamp();
        for (terminals.items) |session| {
            if (!session.pending_snapshot) continue;
            const elapsed = now - session.last_pty_output_ms;
            const remaining: c_int = @intCast(@max(0, SNAPSHOT_COALESCE_MS - elapsed));
            if (poll_timeout < 0 or remaining < poll_timeout) poll_timeout = remaining;
        }

        const nfds: c.nfds_t = @intCast(poll_index);
        const ready = c.poll(&pollfds, nfds, poll_timeout);
        if (ready < 0) {
            if (std.posix.errno(-1) == .INTR) continue;
            return error.PollFailed;
        }

        if (ready == 0) {
            for (terminals.items) |session| {
                if (session.pending_snapshot and std.time.milliTimestamp() - session.last_pty_output_ms >= SNAPSHOT_COALESCE_MS) {
                    try broadcastSnapshot(alloc, session);
                    session.pending_snapshot = false;
                }
            }
            continue;
        }

        if ((pollfds[0].revents & c.POLLIN) != 0) {
            acceptClient(alloc, listen_fd, &terminals) catch {};
        }

        for (polled_sessions[0..session_count], 0..) |session, session_index| {
            if ((pollfds[1 + session_index].revents & c.POLLIN) == 0) continue;
            while (true) {
                const n = c.read(session.pty_fd, &pty_buf, pty_buf.len);
                if (n < 0) {
                    if (std.posix.errno(-1) == .AGAIN) break;
                    return error.PtyReadFailed;
                }
                if (n == 0) break;
                if (session.pending_resize) |size| {
                    try session.terminal.resize(alloc, size.cols, size.rows);
                    session.pending_resize = null;
                }
                try session.stream.nextSlice(pty_buf[0..@intCast(n)]);
                if (n < pty_buf.len) break;
            }
            if (session.metadata_changed) {
                session.metadata_changed = false;
                broadcastTerminals(alloc, &terminals);
            }
            session.pending_snapshot = true;
            session.last_pty_output_ms = std.time.milliTimestamp();
        }

        var client_poll_index: usize = 0;
        while (client_poll_index < client_count) {
            const revents = pollfds[1 + session_count + client_poll_index].revents;
            const session = polled_client_sessions[client_poll_index];
            const client_index = polled_client_indexes[client_poll_index];
            if (client_index >= session.clients.items.len) {
                client_poll_index += 1;
                continue;
            }
            if ((revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) == 0) {
                client_poll_index += 1;
                continue;
            }
            if ((revents & (c.POLLHUP | c.POLLERR)) != 0) {
                const was_writer = session.clients.items[client_index].role == .writer;
                closeClient(session, client_index);
                if (was_writer) broadcastRoles(alloc, session);
                continue;
            }
            const client_fd = session.clients.items[client_index].fd;
            const frame = readWebsocketFrame(alloc, client_fd) catch {
                const was_writer = session.clients.items[client_index].role == .writer;
                closeClient(session, client_index);
                if (was_writer) broadcastRoles(alloc, session);
                continue;
            };
            const payload = frame orelse {
                client_poll_index += 1;
                continue;
            };
            defer alloc.free(payload);
            const msg = decodeClientMessage(payload) catch .unknown;
            switch (msg) {
                .claim_writer => |claim| {
                    if (claim.terminal_id == session.id) {
                        claimWriter(session, client_index);
                        broadcastRoles(alloc, session);
                        broadcastTerminals(alloc, &terminals);
                    }
                },
                .input => |input| {
                    if (input.terminal_id == session.id and session.clients.items[client_index].role == .writer) {
                        try writeAllFd(session.pty_fd, input.data);
                    }
                },
                .resize => |size| {
                    if (size.terminal_id == session.id and session.clients.items[client_index].role == .writer) {
                        try resizePty(session.pty_fd, size.cols, size.rows);
                        session.pending_resize = .{ .cols = size.cols, .rows = size.rows };
                    }
                },
                .scroll => |scroll| {
                    if (scroll.terminal_id == session.id and session.clients.items[client_index].role == .writer and !session.terminal.modes.get(.mouse_event_x10) and
                        !session.terminal.modes.get(.mouse_event_normal) and
                        !session.terminal.modes.get(.mouse_event_button) and
                        !session.terminal.modes.get(.mouse_event_any))
                    {
                        const delta: isize = switch (scroll.direction) {
                            .up => -@as(isize, @intCast(scroll.rows)),
                            .down => @as(isize, @intCast(scroll.rows)),
                        };
                        session.terminal.screens.active.scroll(.{ .delta_row = delta });
                        try broadcastSnapshot(alloc, session);
                    }
                },
                .list_terminals => {
                    sendTerminals(alloc, client_fd, &terminals) catch {};
                },
                .create_terminal => |size| {
                    if (terminals.items.len < MAX_TERMINALS) {
                        const created = try TerminalSession.create(alloc, next_terminal_id, size.cols, size.rows);
                        next_terminal_id += 1;
                        try terminals.append(created);
                        const created_payload = try encodeTerminalCreated(alloc, created);
                        defer alloc.free(created_payload);
                        sendWebsocket(client_fd, created_payload) catch {};
                        broadcastTerminals(alloc, &terminals);
                    }
                },
                .close_terminal => |close| {
                    if (close.terminal_id != DEFAULT_TERMINAL_ID) {
                        if (findSession(&terminals, close.terminal_id)) |target| {
                            for (terminals.items, 0..) |candidate, terminal_index| {
                                if (candidate == target) {
                                    _ = terminals.swapRemove(terminal_index);
                                    target.deinit(alloc);
                                    broadcastTerminals(alloc, &terminals);
                                    break;
                                }
                            }
                        }
                    }
                },
                .unknown => {},
            }
            client_poll_index += 1;
        }

        for (terminals.items) |session| {
            if (session.pending_snapshot and std.time.milliTimestamp() - session.last_pty_output_ms >= SNAPSHOT_COALESCE_MS) {
                try broadcastSnapshot(alloc, session);
                session.pending_snapshot = false;
            }
        }
    }
}

test "unstyled cells do not inherit styled foregrounds" {
    const alloc = std.testing.allocator;

    var terminal: vt.Terminal = try .init(alloc, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(alloc);

    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice("plain \x1b[34mblue\x1b[0m plain");

    var render: vt.RenderState = .empty;
    defer render.deinit(alloc);
    const snap = try snapshot(alloc, &terminal, &render);
    defer alloc.free(snap.cells);

    try std.testing.expectEqual(@as(?u24, null), snap.cells[0].fg_rgb);
    try std.testing.expect(snap.cells[6].fg_rgb != null);
    try std.testing.expectEqual(@as(?u24, null), snap.cells[11].fg_rgb);
}

test "color-only cells preserve background colors" {
    const alloc = std.testing.allocator;

    var terminal: vt.Terminal = try .init(alloc, .{ .cols = 8, .rows = 3 });
    defer terminal.deinit(alloc);

    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice("\x1b[42m        \x1b[0m");

    var render: vt.RenderState = .empty;
    defer render.deinit(alloc);
    const snap = try snapshot(alloc, &terminal, &render);
    defer alloc.free(snap.cells);

    try std.testing.expect(snap.cells[0].bg_rgb != null);
    try std.testing.expectEqual(@as(?u24, null), snap.cells[0].fg_rgb);
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

test "terminal REST content format uses extension before accept header" {
    const html_request = "GET /api/terminals/7 HTTP/1.1\r\nAccept: text/html\r\n\r\n";
    const text_request = "GET /api/terminals/7.html HTTP/1.1\r\nAccept: text/plain\r\n\r\n";
    const plain_request = "GET /api/terminals/7.txt HTTP/1.1\r\nAccept: text/html\r\n\r\n";

    try std.testing.expectEqual(@as(?u32, 7), terminalIdFromApiPath("/api/terminals/7"));
    try std.testing.expectEqual(@as(?u32, 7), terminalIdFromApiPath("/api/terminals/7.html"));
    try std.testing.expectEqual(@as(?u32, 7), terminalIdFromApiPath("/api/terminals/7.txt"));
    try std.testing.expectEqual(TerminalContentFormat.html, terminalContentFormat(html_request, "/api/terminals/7"));
    try std.testing.expectEqual(TerminalContentFormat.html, terminalContentFormat(text_request, "/api/terminals/7.html"));
    try std.testing.expectEqual(TerminalContentFormat.text, terminalContentFormat(plain_request, "/api/terminals/7.txt"));
}

test "terminal websocket path carries terminal id" {
    try std.testing.expectEqual(@as(?u32, 0), terminalIdFromWebsocketPath("/terminal/0.ws"));
    try std.testing.expectEqual(@as(?u32, 42), terminalIdFromWebsocketPath("/terminal/42.ws"));
    try std.testing.expectEqual(@as(?u32, null), terminalIdFromWebsocketPath("/api/terminal?id=42"));
    try std.testing.expectEqual(@as(?u32, null), terminalIdFromWebsocketPath("/terminal/42"));
    try std.testing.expectEqual(@as(?u32, null), terminalIdFromWebsocketPath("/terminal/nope.ws"));
}

test "terminal REST renderers emit text and escaped html" {
    const alloc = std.testing.allocator;
    var cells = [_]Cell{
        .{ .char = 'o' },
        .{ .char = 'k' },
        .{ .char = '<', .fg_rgb = 0xff0000, .flags = 0x01 },
        .{ .char = ' ' },
    };
    const snap: Snapshot = .{
        .cols = 4,
        .rows = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = false,
        .mouse_reporting = false,
        .cells = &cells,
    };

    const text = try snapshotText(alloc, snap);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("ok<", text);

    const html = try snapshotHtml(alloc, 2, snap);
    defer alloc.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "ghostd terminal 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "ok<span style=\"color:#ff0000;font-weight:700;\">&lt;</span>") != null);
}
