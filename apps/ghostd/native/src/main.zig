const std = @import("std");
const vt = @import("ghostty-vt");

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
    @cInclude("util.h");
});

const DEFAULT_COLOR: u16 = 256;
const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;
const MAX_CLIENTS: usize = 64;
const SNAPSHOT_COALESCE_MS: i64 = 16;
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

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

    fn label(self: Role) []const u8 {
        return switch (self) {
            .writer => "writer",
            .reader => "reader",
        };
    }
};

const ClientMessage = union(enum) {
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    scroll: struct { rows: u16, direction: []const u8 },
    claim_writer,
    unknown,
};

const Client = struct {
    fd: c_int,
    role: Role,
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
    var entries: u16 = 4;
    if (cell.fg_rgb != null) entries += 1;
    if (cell.bg_rgb != null) entries += 1;
    try writer.map(entries);
    try writer.str("char");
    try writer.uint(if (cell.char == 0) 32 else cell.char);
    try writer.str("fg");
    try writer.uint(cell.fg);
    try writer.str("bg");
    try writer.uint(cell.bg);
    try writer.str("flags");
    try writer.uint(cell.flags);
    if (cell.fg_rgb) |rgb| {
        try writer.str("fgRgb");
        try writer.uint(rgb);
    }
    if (cell.bg_rgb) |rgb| {
        try writer.str("bgRgb");
        try writer.uint(rgb);
    }
}

fn encodeSnapshot(alloc: std.mem.Allocator, snap: Snapshot, role: Role) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();

    try writer.map(10);
    try writer.str("type");
    try writer.str("snapshot");
    try writer.str("sessionId");
    try writer.str("default");
    try writer.str("role");
    try writer.str(role.label());
    try writer.str("cols");
    try writer.uint(snap.cols);
    try writer.str("rows");
    try writer.uint(snap.rows);
    try writer.str("cursor");
    try writer.map(3);
    try writer.str("row");
    try writer.uint(snap.cursor_row);
    try writer.str("col");
    try writer.uint(snap.cursor_col);
    try writer.str("visible");
    try writer.boolValue(snap.cursor_visible);
    try writer.str("mouseReporting");
    try writer.boolValue(snap.mouse_reporting);
    try writer.str("scrollback");
    try writer.array(0);
    try writer.str("scrollbackLineLens");
    try writer.array(0);
    try writer.str("viewport");
    try writer.array(snap.rows);
    for (0..snap.rows) |row| {
        try writer.map(2);
        try writer.str("index");
        try writer.uint(@intCast(row));
        try writer.str("cells");
        try writer.array(snap.cols);
        const start = row * @as(usize, snap.cols);
        for (snap.cells[start .. start + snap.cols]) |cell| {
            try encodeCell(&writer, cell);
        }
    }

    return writer.buf.toOwnedSlice();
}

fn encodeRole(alloc: std.mem.Allocator, role: Role) ![]u8 {
    var writer = MsgpackWriter.init(alloc);
    errdefer writer.deinit();
    try writer.map(2);
    try writer.str("type");
    try writer.str("role");
    try writer.str("role");
    try writer.str(role.label());
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

fn decodeClientMessage(data: []const u8) !ClientMessage {
    var reader = MsgpackReader{ .data = data };
    const marker = try reader.readByte();
    const pairs = try reader.readLen(marker);
    var kind: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var direction: ?[]const u8 = null;
    var cols: ?u16 = null;
    var rows: ?u16 = null;

    for (0..pairs) |_| {
        const key = try reader.readString();
        if (std.mem.eql(u8, key, "type")) {
            kind = try reader.readString();
        } else if (std.mem.eql(u8, key, "data")) {
            input = try reader.readString();
        } else if (std.mem.eql(u8, key, "direction")) {
            direction = try reader.readString();
        } else if (std.mem.eql(u8, key, "cols")) {
            cols = @intCast(try reader.readUint());
        } else if (std.mem.eql(u8, key, "rows")) {
            rows = @intCast(try reader.readUint());
        } else {
            try reader.skip();
        }
    }

    if (kind) |value| {
        if (std.mem.eql(u8, value, "input")) return .{ .input = input orelse "" };
        if (std.mem.eql(u8, value, "resize") and cols != null and rows != null) {
            return .{ .resize = .{ .cols = cols.?, .rows = rows.? } };
        }
        if (std.mem.eql(u8, value, "scroll") and rows != null and direction != null) {
            return .{ .scroll = .{ .rows = rows.?, .direction = direction.? } };
        }
        if (std.mem.eql(u8, value, "claimWriter")) return .claim_writer;
    }
    return .unknown;
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
            if (c.__error().* == c.EINTR) continue;
            if (c.__error().* == c.EAGAIN) {
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

fn createListenSocket(port: u16) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var yes: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    addr.sin_addr.s_addr = c.htonl(c.INADDR_LOOPBACK);
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

fn sendHttp(fd: c_int, status: []const u8, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
    try writeAllFd(fd, text);
    try writeAllFd(fd, body);
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    return "application/octet-stream";
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

fn sendStatic(alloc: std.mem.Allocator, fd: c_int, request: []const u8) !void {
    const path = requestPath(request);
    if (std.mem.indexOf(u8, path, "..") != null) {
        try sendHttp(fd, "400 Bad Request", "bad path\n");
        return;
    }

    const rel = if (std.mem.eql(u8, path, "/"))
        "dist/index.html"
    else
        try std.fmt.allocPrint(alloc, "dist{s}", .{path});
    defer if (!std.mem.eql(u8, path, "/")) alloc.free(rel);

    const body = std.fs.cwd().readFileAlloc(alloc, rel, 16 * 1024 * 1024) catch {
        try sendHttp(fd, "404 Not Found", "ghostd native client assets are missing; run `pnpm --filter ghostd build`\n");
        return;
    };
    defer alloc.free(body);

    var header: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ contentType(rel), body.len });
    try writeAllFd(fd, text);
    try writeAllFd(fd, body);
}

fn acceptClient(alloc: std.mem.Allocator, listen_fd: c_int, clients: *std.array_list.Managed(Client), terminal: *vt.Terminal, render: *vt.RenderState) !void {
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
        try sendStatic(alloc, fd, request);
        return;
    };

    const accept = try websocketAccept(alloc, key);
    defer alloc.free(accept);
    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
    try writeAllFd(fd, response);

    const role: Role = if (clients.items.len == 0) .writer else .reader;
    try clients.append(.{ .fd = fd, .role = role });
    const client_index = clients.items.len - 1;

    const snap = try snapshot(alloc, terminal, render);
    defer alloc.free(snap.cells);
    const payload = try encodeSnapshot(alloc, snap, role);
    defer alloc.free(payload);
    sendWebsocket(fd, payload) catch {
        closeClient(clients, client_index);
        return;
    };
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
        if (c.__error().* == c.EAGAIN) return null;
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

fn closeClient(clients: *std.array_list.Managed(Client), index: usize) void {
    const was_writer = clients.items[index].role == .writer;
    _ = c.close(clients.items[index].fd);
    _ = clients.swapRemove(index);
    if (was_writer and clients.items.len > 0) clients.items[0].role = .writer;
}

fn broadcastSnapshot(alloc: std.mem.Allocator, clients: *std.array_list.Managed(Client), terminal: *vt.Terminal, render: *vt.RenderState) !void {
    const snap = try snapshot(alloc, terminal, render);
    defer alloc.free(snap.cells);
    var i: usize = 0;
    while (i < clients.items.len) {
        const payload = try encodeSnapshot(alloc, snap, clients.items[i].role);
        defer alloc.free(payload);
        sendWebsocket(clients.items[i].fd, payload) catch {
            closeClient(clients, i);
            continue;
        };
        i += 1;
    }
}

fn broadcastRoles(alloc: std.mem.Allocator, clients: *std.array_list.Managed(Client)) void {
    var i: usize = 0;
    while (i < clients.items.len) {
        const payload = encodeRole(alloc, clients.items[i].role) catch return;
        defer alloc.free(payload);
        sendWebsocket(clients.items[i].fd, payload) catch {
            closeClient(clients, i);
            continue;
        };
        i += 1;
    }
}

fn claimWriter(clients: *std.array_list.Managed(Client), index: usize) void {
    if (index >= clients.items.len) return;
    for (clients.items) |*client| client.role = .reader;
    clients.items[index].role = .writer;
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const port = parsePort(args);

    var terminal: vt.Terminal = try .init(alloc, .{
        .cols = DEFAULT_COLS,
        .rows = DEFAULT_ROWS,
        .max_scrollback = 10 * 1024 * 1024,
    });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    var render: vt.RenderState = .empty;
    defer render.deinit(alloc);

    const listen_fd = try createListenSocket(port);
    defer _ = c.close(listen_fd);
    const pty_fd = try spawnPty(DEFAULT_COLS, DEFAULT_ROWS);
    defer _ = c.close(pty_fd);

    var clients = std.array_list.Managed(Client).init(alloc);
    defer {
        for (clients.items) |client| _ = c.close(client.fd);
        clients.deinit();
    }

    std.debug.print("ghostd native listening on http://127.0.0.1:{d}\n", .{port});

    var pty_buf: [8192]u8 = undefined;
    var pending_resize: ?struct { cols: u16, rows: u16 } = null;
    var pending_snapshot = false;
    var last_pty_output_ms: i64 = 0;
    while (true) {
        var pollfds: [2 + MAX_CLIENTS]c.struct_pollfd = undefined;
        const polled_clients = clients.items.len;
        pollfds[0] = .{ .fd = listen_fd, .events = c.POLLIN, .revents = 0 };
        pollfds[1] = .{ .fd = pty_fd, .events = c.POLLIN, .revents = 0 };
        for (clients.items[0..polled_clients], 0..) |client, i| {
            pollfds[2 + i] = .{ .fd = client.fd, .events = c.POLLIN, .revents = 0 };
        }

        const nfds: c.nfds_t = @intCast(2 + polled_clients);
        const poll_timeout: c_int = if (pending_snapshot) blk: {
            const elapsed = std.time.milliTimestamp() - last_pty_output_ms;
            break :blk @intCast(@max(0, SNAPSHOT_COALESCE_MS - elapsed));
        } else -1;
        const ready = c.poll(&pollfds, nfds, poll_timeout);
        if (ready < 0) {
            if (c.__error().* == c.EINTR) continue;
            return error.PollFailed;
        }

        if (ready == 0) {
            if (pending_snapshot) {
                try broadcastSnapshot(alloc, &clients, &terminal, &render);
                pending_snapshot = false;
            }
            continue;
        }

        if ((pollfds[0].revents & c.POLLIN) != 0 and clients.items.len < MAX_CLIENTS) {
            acceptClient(alloc, listen_fd, &clients, &terminal, &render) catch {};
        }

        if ((pollfds[1].revents & c.POLLIN) != 0) {
            while (true) {
                const n = c.read(pty_fd, &pty_buf, pty_buf.len);
                if (n < 0) {
                    if (c.__error().* == c.EAGAIN) break;
                    return error.PtyReadFailed;
                }
                if (n == 0) return;
                if (pending_resize) |size| {
                    try terminal.resize(alloc, size.cols, size.rows);
                    pending_resize = null;
                }
                try stream.nextSlice(pty_buf[0..@intCast(n)]);
                if (n < pty_buf.len) break;
            }
            pending_snapshot = true;
            last_pty_output_ms = std.time.milliTimestamp();
        }

        var idx: usize = 0;
        while (idx < polled_clients and idx < clients.items.len) {
            const revents = pollfds[2 + idx].revents;
            if ((revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) == 0) {
                idx += 1;
                continue;
            }
            if ((revents & (c.POLLHUP | c.POLLERR)) != 0) {
                const was_writer = clients.items[idx].role == .writer;
                closeClient(&clients, idx);
                if (was_writer) broadcastRoles(alloc, &clients);
                continue;
            }
            const frame = readWebsocketFrame(alloc, clients.items[idx].fd) catch {
                const was_writer = clients.items[idx].role == .writer;
                closeClient(&clients, idx);
                if (was_writer) broadcastRoles(alloc, &clients);
                continue;
            };
            const payload = frame orelse {
                idx += 1;
                continue;
            };
            defer alloc.free(payload);
            const msg = decodeClientMessage(payload) catch .unknown;
            switch (msg) {
                .claim_writer => {
                    claimWriter(&clients, idx);
                    broadcastRoles(alloc, &clients);
                },
                .input => |data| {
                    if (clients.items[idx].role == .writer) try writeAllFd(pty_fd, data);
                },
                .resize => |size| {
                    if (clients.items[idx].role == .writer) {
                        try resizePty(pty_fd, size.cols, size.rows);
                        pending_resize = .{ .cols = size.cols, .rows = size.rows };
                    }
                },
                .scroll => |scroll| {
                    if (clients.items[idx].role == .writer and !terminal.modes.get(.mouse_event_x10) and
                        !terminal.modes.get(.mouse_event_normal) and
                        !terminal.modes.get(.mouse_event_button) and
                        !terminal.modes.get(.mouse_event_any))
                    {
                        const delta: isize = if (std.mem.eql(u8, scroll.direction, "up"))
                            -@as(isize, @intCast(scroll.rows))
                        else
                            @as(isize, @intCast(scroll.rows));
                        terminal.screens.active.scroll(.{ .delta_row = delta });
                        try broadcastSnapshot(alloc, &clients, &terminal, &render);
                    }
                },
                .unknown => {},
            }
            idx += 1;
        }

        if (pending_snapshot and std.time.milliTimestamp() - last_pty_output_ms >= SNAPSHOT_COALESCE_MS) {
            try broadcastSnapshot(alloc, &clients, &terminal, &render);
            pending_snapshot = false;
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

test "decodes client input and resize messages" {
    const input = [_]u8{ 0x82, 0xa4, 't', 'y', 'p', 'e', 0xa5, 'i', 'n', 'p', 'u', 't', 0xa4, 'd', 'a', 't', 'a', 0xa1, 'x' };
    const msg = try decodeClientMessage(&input);
    try std.testing.expectEqualStrings("x", msg.input);

    const resize = [_]u8{ 0x83, 0xa4, 't', 'y', 'p', 'e', 0xa6, 'r', 'e', 's', 'i', 'z', 'e', 0xa4, 'c', 'o', 'l', 's', 0xcc, 120, 0xa4, 'r', 'o', 'w', 's', 0x28 };
    const resize_msg = try decodeClientMessage(&resize);
    try std.testing.expectEqual(@as(u16, 120), resize_msg.resize.cols);
    try std.testing.expectEqual(@as(u16, 40), resize_msg.resize.rows);

    const claim = [_]u8{ 0x81, 0xa4, 't', 'y', 'p', 'e', 0xab, 'c', 'l', 'a', 'i', 'm', 'W', 'r', 'i', 't', 'e', 'r' };
    const claim_msg = try decodeClientMessage(&claim);
    try std.testing.expect(claim_msg == .claim_writer);

    const scroll = [_]u8{ 0x83, 0xa4, 't', 'y', 'p', 'e', 0xa6, 's', 'c', 'r', 'o', 'l', 'l', 0xa4, 'r', 'o', 'w', 's', 0x03, 0xa9, 'd', 'i', 'r', 'e', 'c', 't', 'i', 'o', 'n', 0xa2, 'u', 'p' };
    const scroll_msg = try decodeClientMessage(&scroll);
    try std.testing.expectEqual(@as(u16, 3), scroll_msg.scroll.rows);
    try std.testing.expectEqualStrings("up", scroll_msg.scroll.direction);
}
