const std = @import("std");
const vt = @import("ghostty-vt");
const protocol = @import("protocol.zig");

pub const Cell = protocol.Cell;
pub const Snapshot = protocol.Snapshot;

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

pub fn capture(alloc: std.mem.Allocator, terminal: *vt.Terminal, render: *vt.RenderState) !Snapshot {
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

pub fn text(alloc: std.mem.Allocator, snap: Snapshot) ![]u8 {
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

pub fn html(alloc: std.mem.Allocator, terminal_id: u32, snap: Snapshot) ![]u8 {
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

test "unstyled cells do not inherit styled foregrounds" {
    const alloc = std.testing.allocator;

    var terminal: vt.Terminal = try .init(alloc, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(alloc);

    var stream = terminal.vtStream();
    defer stream.deinit();
    try stream.nextSlice("plain \x1b[34mblue\x1b[0m plain");

    var render: vt.RenderState = .empty;
    defer render.deinit(alloc);
    const snap = try capture(alloc, &terminal, &render);
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
    const snap = try capture(alloc, &terminal, &render);
    defer alloc.free(snap.cells);

    try std.testing.expect(snap.cells[0].bg_rgb != null);
    try std.testing.expectEqual(@as(?u24, null), snap.cells[0].fg_rgb);
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

    const rendered_text = try text(alloc, snap);
    defer alloc.free(rendered_text);
    try std.testing.expectEqualStrings("ok<", rendered_text);

    const rendered_html = try html(alloc, 2, snap);
    defer alloc.free(rendered_html);
    try std.testing.expect(std.mem.indexOf(u8, rendered_html, "ghostd terminal 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_html, "ok<span style=\"color:#ff0000;font-weight:700;\">&lt;</span>") != null);
}
