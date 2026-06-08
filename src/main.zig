const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const StreamAction = vt.StreamAction;
const embedded_assets = @import("embedded_assets.zig");
const protocol = @import("protocol.zig");
const snapshot_mod = @import("snapshot.zig");

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

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;
const MAX_CLIENTS: usize = 64;
const MAX_TERMINALS: usize = 16;
const MAX_TITLE_BYTES: usize = 256;
const MAX_PWD_BYTES: usize = 512;
const SNAPSHOT_COALESCE_MS: i64 = 4;
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const DEFAULT_TERMINAL_ID: u32 = 0;
const PROTOCOL_BINLOG_MAGIC = "GHOSTD-PROTOCOL-BINLOG\x00\x01";

const ServerOpcode = protocol.ServerOpcode;
const WireRole = protocol.WireRole;
const ScrollDirection = protocol.ScrollDirection;
const MsgpackWriter = protocol.MsgpackWriter;
const Cell = protocol.Cell;
const Snapshot = protocol.Snapshot;
const CellRange = protocol.CellRange;
const ClientMessage = protocol.ClientMessage;
const buildChangedRanges = protocol.buildChangedRanges;
const decodeClientMessage = protocol.decodeClientMessage;
const encodeRows = protocol.encodeRows;
const snapshot = snapshot_mod.capture;

const TerminalContentFormat = enum {
    html,
    text,
};

const ProtocolDirection = enum(u8) {
    in = 0,
    out = 1,
};

const ProtocolBinlog = struct {
    file: ?std.fs.File = null,

    fn open(path: ?[]const u8) !ProtocolBinlog {
        const file_path = path orelse return .{};
        var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        errdefer file.close();
        try file.writeAll(PROTOCOL_BINLOG_MAGIC);
        return .{ .file = file };
    }

    fn close(self: *ProtocolBinlog) void {
        if (self.file) |file| file.close();
        self.file = null;
    }

    fn write(self: *ProtocolBinlog, direction: ProtocolDirection, fd: c_int, payload: []const u8) !void {
        const file = self.file orelse return;
        var header: [17]u8 = undefined;
        header[0] = @intFromEnum(direction);
        std.mem.writeInt(u32, header[1..5], @bitCast(fd), .little);
        std.mem.writeInt(u64, header[5..13], @intCast(std.time.nanoTimestamp()), .little);
        std.mem.writeInt(u32, header[13..17], @intCast(payload.len), .little);
        try file.writeAll(&header);
        try file.writeAll(payload);
    }
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
    last_snapshot_cells: []Cell = &.{},
    last_snapshot_cols: u16 = 0,
    last_snapshot_rows: u16 = 0,

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
        session.last_snapshot_cells = &.{};
        session.last_snapshot_cols = 0;
        session.last_snapshot_rows = 0;
        session.pty_fd = try spawnPty(cols, rows);
        return session;
    }

    fn deinit(self: *TerminalSession, alloc: std.mem.Allocator) void {
        for (self.clients.items) |client| _ = c.close(client.fd);
        self.clients.deinit();
        self.stream.deinit();
        self.render.deinit(alloc);
        self.terminal.deinit(alloc);
        if (self.last_snapshot_cells.len > 0) alloc.free(self.last_snapshot_cells);
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

fn parseProtocolBinlogPath(args: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--protocol-binlog") and i + 1 < args.len) {
            return args[i + 1];
        }
        if (std.mem.startsWith(u8, args[i], "--protocol-binlog=")) {
            return args[i]["--protocol-binlog=".len..];
        }
    }
    return null;
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
        \\Usage: ghostd [--host HOST] [--port PORT] [--protocol-binlog FILE]
        \\
        \\Options:
        \\  -h, --help             Show this help message.
        \\  --host HOST            Listen on HOST (default: 127.0.0.1, or HOST env var).
        \\  --port PORT            Listen on PORT (default: 7341, or PORT env var).
        \\  --protocol-binlog FILE Write binary websocket protocol payload log to FILE.
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
    const raw = requestTarget(request);
    const query = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    return raw[0..query];
}

fn requestTarget(request: []const u8) []const u8 {
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next();
    return parts.next() orelse "/";
}

fn requestWantsWriter(request: []const u8) bool {
    const target = requestTarget(request);
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var params = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (params.next()) |param| {
        if (std.mem.eql(u8, param, "writer=1")) return true;
    }
    return false;
}

fn autoClaimWriterEnabled() bool {
    const value = std.posix.getenv("GHOSTD_AUTO_CLAIM_WRITER") orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
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
        .html => try snapshot_mod.html(alloc, session.id, snap),
        .text => try snapshot_mod.text(alloc, snap),
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

fn sendTerminals(alloc: std.mem.Allocator, logger: *ProtocolBinlog, fd: c_int, terminals: *std.array_list.Managed(*TerminalSession)) !void {
    const payload = try encodeTerminals(alloc, terminals);
    defer alloc.free(payload);
    try sendWebsocket(logger, fd, payload);
}

fn broadcastTerminals(alloc: std.mem.Allocator, logger: *ProtocolBinlog, terminals: *std.array_list.Managed(*TerminalSession)) void {
    const payload = encodeTerminals(alloc, terminals) catch return;
    defer alloc.free(payload);
    for (terminals.items) |session| {
        var i: usize = 0;
        while (i < session.clients.items.len) {
            sendWebsocket(logger, session.clients.items[i].fd, payload) catch {
                closeClient(session, i);
                continue;
            };
            i += 1;
        }
    }
}

fn acceptClient(alloc: std.mem.Allocator, logger: *ProtocolBinlog, listen_fd: c_int, terminals: *std.array_list.Managed(*TerminalSession)) !void {
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

    const role: Role = if (session.clients.items.len == 0 or requestWantsWriter(request) or autoClaimWriterEnabled()) .writer else .reader;
    if (role == .writer) {
        for (session.clients.items) |*client| client.role = .reader;
    }
    try session.clients.append(.{ .fd = fd, .role = role, .terminal_id = session.id });
    const client_index = session.clients.items.len - 1;

    const snap = try snapshot(alloc, &session.terminal, &session.render);
    defer alloc.free(snap.cells);
    const payload = try protocol.encodeSnapshot(alloc, session.id, snap, role.wire());
    defer alloc.free(payload);
    sendWebsocket(logger, fd, payload) catch {
        closeClient(session, client_index);
        return;
    };
    if (session.last_snapshot_cells.len == 0) {
        session.last_snapshot_cells = try alloc.dupe(Cell, snap.cells);
        session.last_snapshot_cols = snap.cols;
        session.last_snapshot_rows = snap.rows;
    }
    sendTerminals(alloc, logger, fd, terminals) catch {};
}

fn sendWebsocket(logger: *ProtocolBinlog, fd: c_int, payload: []const u8) !void {
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
    try logger.write(.out, fd, payload);
    try writeAllFd(fd, header[0..header_len]);
    try writeAllFd(fd, payload);
}

fn readWebsocketFrame(alloc: std.mem.Allocator, logger: *ProtocolBinlog, fd: c_int) !?[]u8 {
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
    try logger.write(.in, fd, payload);
    return payload;
}

fn closeClient(session: *TerminalSession, index: usize) void {
    const was_writer = session.clients.items[index].role == .writer;
    _ = c.close(session.clients.items[index].fd);
    _ = session.clients.swapRemove(index);
    if (was_writer and session.clients.items.len > 0) session.clients.items[0].role = .writer;
}

fn broadcastSnapshot(alloc: std.mem.Allocator, logger: *ProtocolBinlog, session: *TerminalSession) !void {
    const snap = try snapshot(alloc, &session.terminal, &session.render);
    defer alloc.free(snap.cells);

    const dimensions_changed = session.last_snapshot_cols != snap.cols or
        session.last_snapshot_rows != snap.rows or
        session.last_snapshot_cells.len != snap.cells.len;
    const use_full_snapshot = dimensions_changed or session.last_snapshot_cells.len == 0;

    var changed_ranges = if (use_full_snapshot)
        std.array_list.Managed(CellRange).init(alloc)
    else
        try buildChangedRanges(alloc, session.last_snapshot_cells, snap.cells, snap.cols, snap.rows);
    defer changed_ranges.deinit();

    if (!use_full_snapshot and changed_ranges.items.len == 0) {
        return;
    }

    var i: usize = 0;
    while (i < session.clients.items.len) {
        const payload = if (use_full_snapshot)
            try protocol.encodeSnapshot(alloc, session.id, snap, session.clients.items[i].role.wire())
        else
            try encodeRows(alloc, session.id, snap, changed_ranges.items);
        defer alloc.free(payload);
        sendWebsocket(logger, session.clients.items[i].fd, payload) catch {
            closeClient(session, i);
            continue;
        };
        i += 1;
    }

    if (dimensions_changed) {
        if (session.last_snapshot_cells.len > 0) alloc.free(session.last_snapshot_cells);
        session.last_snapshot_cells = try alloc.dupe(Cell, snap.cells);
    } else {
        @memcpy(session.last_snapshot_cells, snap.cells);
    }
    session.last_snapshot_cols = snap.cols;
    session.last_snapshot_rows = snap.rows;
}

fn broadcastRoles(alloc: std.mem.Allocator, logger: *ProtocolBinlog, session: *TerminalSession) void {
    var i: usize = 0;
    while (i < session.clients.items.len) {
        const payload = encodeRole(alloc, session.id, session.clients.items[i].role) catch return;
        defer alloc.free(payload);
        sendWebsocket(logger, session.clients.items[i].fd, payload) catch {
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
    var protocol_binlog = try ProtocolBinlog.open(parseProtocolBinlogPath(args));
    defer protocol_binlog.close();

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
                    try broadcastSnapshot(alloc, &protocol_binlog, session);
                    session.pending_snapshot = false;
                }
            }
            continue;
        }

        if ((pollfds[0].revents & c.POLLIN) != 0) {
            acceptClient(alloc, &protocol_binlog, listen_fd, &terminals) catch {};
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
                broadcastTerminals(alloc, &protocol_binlog, &terminals);
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
                if (was_writer) broadcastRoles(alloc, &protocol_binlog, session);
                continue;
            }
            const client_fd = session.clients.items[client_index].fd;
            const frame = readWebsocketFrame(alloc, &protocol_binlog, client_fd) catch {
                const was_writer = session.clients.items[client_index].role == .writer;
                closeClient(session, client_index);
                if (was_writer) broadcastRoles(alloc, &protocol_binlog, session);
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
                        broadcastRoles(alloc, &protocol_binlog, session);
                        broadcastTerminals(alloc, &protocol_binlog, &terminals);
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
                        try broadcastSnapshot(alloc, &protocol_binlog, session);
                    }
                },
                .list_terminals => {
                    sendTerminals(alloc, &protocol_binlog, client_fd, &terminals) catch {};
                },
                .create_terminal => |size| {
                    if (terminals.items.len < MAX_TERMINALS) {
                        const created = try TerminalSession.create(alloc, next_terminal_id, size.cols, size.rows);
                        next_terminal_id += 1;
                        try terminals.append(created);
                        const created_payload = try encodeTerminalCreated(alloc, created);
                        defer alloc.free(created_payload);
                        sendWebsocket(&protocol_binlog, client_fd, created_payload) catch {};
                        broadcastTerminals(alloc, &protocol_binlog, &terminals);
                    }
                },
                .close_terminal => |close| {
                    if (close.terminal_id != DEFAULT_TERMINAL_ID) {
                        if (findSession(&terminals, close.terminal_id)) |target| {
                            for (terminals.items, 0..) |candidate, terminal_index| {
                                if (candidate == target) {
                                    _ = terminals.swapRemove(terminal_index);
                                    target.deinit(alloc);
                                    broadcastTerminals(alloc, &protocol_binlog, &terminals);
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
                try broadcastSnapshot(alloc, &protocol_binlog, session);
                session.pending_snapshot = false;
            }
        }
    }
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

test "protocol binlog writes binary framed payloads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(path);
    const file_path = try std.fs.path.join(alloc, &.{ path, "protocol.binlog" });
    defer alloc.free(file_path);

    var logger = try ProtocolBinlog.open(file_path);
    defer logger.close();
    try logger.write(.in, 42, &.{ 0x93, 0x01, 0x00 });
    try logger.write(.out, 42, &.{ 0x92, 0x03 });
    logger.close();

    const contents = try std.fs.cwd().readFileAlloc(alloc, file_path, 1024);
    defer alloc.free(contents);

    try std.testing.expect(std.mem.startsWith(u8, contents, PROTOCOL_BINLOG_MAGIC));
    var offset: usize = PROTOCOL_BINLOG_MAGIC.len;
    try std.testing.expectEqual(@as(u8, 0), contents[offset]);
    try std.testing.expectEqual(@as(u32, 42), readU32Le(contents[offset + 1 .. offset + 5]));
    try std.testing.expectEqual(@as(u32, 3), readU32Le(contents[offset + 13 .. offset + 17]));
    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0x01, 0x00 }, contents[offset + 17 .. offset + 20]);

    offset += 20;
    try std.testing.expectEqual(@as(u8, 1), contents[offset]);
    try std.testing.expectEqual(@as(u32, 42), readU32Le(contents[offset + 1 .. offset + 5]));
    try std.testing.expectEqual(@as(u32, 2), readU32Le(contents[offset + 13 .. offset + 17]));
    try std.testing.expectEqualSlices(u8, &.{ 0x92, 0x03 }, contents[offset + 17 .. offset + 19]);
    try std.testing.expectEqual(offset + 19, contents.len);
}

fn readU32Le(bytes: []const u8) u32 {
    var fixed: [4]u8 = undefined;
    @memcpy(&fixed, bytes[0..4]);
    return std.mem.readInt(u32, &fixed, .little);
}
