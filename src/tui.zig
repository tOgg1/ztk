const std = @import("std");
const ui = @import("ui.zig");

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
    tab,
    ctrl_c,
    ctrl_d,
    backspace,
    unknown,
};

pub const Terminal = struct {
    tty: std.fs.File,
    original_termios: std.posix.termios,
    width: u16,
    height: u16,
    in_raw_mode: bool,

    pub fn init() !Terminal {
        const tty = std.fs.File.stdin();

        // Get terminal size
        var size = std.posix.system.winsize{
            .col = 80,
            .row = 24,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = std.posix.system.ioctl(tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size));

        const original = try std.posix.tcgetattr(tty.handle);

        return Terminal{
            .tty = tty,
            .original_termios = original,
            .width = size.col,
            .height = size.row,
            .in_raw_mode = false,
        };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.in_raw_mode) {
            self.exitRawMode();
        }
    }

    pub fn enterRawMode(self: *Terminal) !void {
        var raw = self.original_termios;

        // Disable echo, canonical mode, signals, extended input processing
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Disable software flow control, CR-to-NL
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Disable output processing
        raw.oflag.OPOST = false;

        // Set character size to 8 bits
        raw.cflag.CSIZE = .CS8;

        // Minimum bytes for read, timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(self.tty.handle, .FLUSH, raw);
        self.in_raw_mode = true;

        // Hide cursor and clear screen
        self.hideCursor();
        self.clear();
    }

    pub fn exitRawMode(self: *Terminal) void {
        // Show cursor
        self.showCursor();

        // Restore original terminal settings
        std.posix.tcsetattr(self.tty.handle, .FLUSH, self.original_termios) catch {};
        self.in_raw_mode = false;
    }

    pub fn readKey(self: *Terminal) !Key {
        var buf: [1]u8 = undefined;
        const n = try self.tty.read(&buf);
        if (n == 0) return .ctrl_d;

        return switch (buf[0]) {
            '\x1B' => self.parseEscapeSequence(),
            '\r', '\n' => .enter,
            '\t' => .tab,
            3 => .ctrl_c, // Ctrl+C
            4 => .ctrl_d, // Ctrl+D
            127, 8 => .backspace, // Backspace / Ctrl+H
            else => .{ .char = buf[0] },
        };
    }

    fn parseEscapeSequence(self: *Terminal) Key {
        // Set short timeout for escape sequence detection
        var raw = std.posix.tcgetattr(self.tty.handle) catch return .escape;
        const original_min = raw.cc[@intFromEnum(std.posix.V.MIN)];
        const original_time = raw.cc[@intFromEnum(std.posix.V.TIME)];

        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 0.1 second timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        std.posix.tcsetattr(self.tty.handle, .NOW, raw) catch return .escape;
        defer {
            raw.cc[@intFromEnum(std.posix.V.TIME)] = original_time;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = original_min;
            std.posix.tcsetattr(self.tty.handle, .NOW, raw) catch {};
        }

        var seq: [3]u8 = undefined;
        const n = self.tty.read(&seq) catch return .escape;

        if (n == 0) return .escape;
        if (n >= 2 and seq[0] == '[') {
            return switch (seq[1]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .unknown,
            };
        }
        return .unknown;
    }

    pub fn clear(self: *Terminal) void {
        _ = self;
        // Clear screen and move cursor to top-left
        const stdout = std.posix.STDOUT_FILENO;
        _ = std.posix.write(stdout, "\x1b[2J\x1b[H") catch {};
    }

    pub fn moveTo(self: *Terminal, row: u16, col: u16) void {
        _ = self;
        const stdout = std.posix.STDOUT_FILENO;
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return;
        _ = std.posix.write(stdout, seq) catch {};
    }

    pub fn hideCursor(self: *Terminal) void {
        _ = self;
        const stdout = std.posix.STDOUT_FILENO;
        _ = std.posix.write(stdout, "\x1b[?25l") catch {};
    }

    pub fn showCursor(self: *Terminal) void {
        _ = self;
        const stdout = std.posix.STDOUT_FILENO;
        _ = std.posix.write(stdout, "\x1b[?25h") catch {};
    }

    pub fn clearLine(self: *Terminal) void {
        _ = self;
        const stdout = std.posix.STDOUT_FILENO;
        _ = std.posix.write(stdout, "\x1b[2K") catch {};
    }

    pub fn getSize(self: *Terminal) !struct { width: u16, height: u16 } {
        var size = std.posix.system.winsize{
            .col = 80,
            .row = 24,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = std.posix.system.ioctl(self.tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
        self.width = size.col;
        self.height = size.row;
        return .{ .width = size.col, .height = size.row };
    }
};

pub const ItemType = enum {
    review_approved,
    review_changes_requested,
    review_commented,
    review_pending,
    comment,
};

pub const ListItem = struct {
    primary: []const u8, // main text
    secondary: ?[]const u8, // subtitle/metadata
    detail: ?[]const u8, // expandable content
    context: ?*anyopaque, // pointer to underlying data
    item_type: ItemType = .comment, // type for styling
};

pub const ListView = struct {
    items: []const ListItem,
    selected: usize,
    scroll_offset: usize,
    visible_height: u16,
    expanded: bool,

    pub fn init(items: []const ListItem, visible_height: u16) ListView {
        return .{
            .items = items,
            .selected = 0,
            .scroll_offset = 0,
            .visible_height = visible_height,
            .expanded = false,
        };
    }

    pub fn moveUp(self: *ListView) void {
        if (self.selected > 0) {
            self.selected -= 1;
            if (self.selected < self.scroll_offset) {
                self.scroll_offset = self.selected;
            }
        }
    }

    pub fn moveDown(self: *ListView) void {
        if (self.selected + 1 < self.items.len) {
            self.selected += 1;
            // Ensure selected item is visible
            const max_visible = self.scroll_offset + self.visible_height - 1;
            if (self.selected > max_visible) {
                self.scroll_offset = self.selected - self.visible_height + 1;
            }
        }
    }

    pub fn toggleExpanded(self: *ListView) void {
        self.expanded = !self.expanded;
    }

    pub fn selectedItem(self: *const ListView) ?*const ListItem {
        if (self.items.len == 0) return null;
        return &self.items[self.selected];
    }

    fn getTypeIcon(item_type: ItemType) []const u8 {
        return switch (item_type) {
            .review_approved => ui.Style.green ++ ui.Style.check ++ ui.Style.reset,
            .review_changes_requested => ui.Style.red ++ ui.Style.cross ++ ui.Style.reset,
            .review_commented => ui.Style.blue ++ "●" ++ ui.Style.reset,
            .review_pending => ui.Style.dim ++ ui.Style.pending ++ ui.Style.reset,
            .comment => ui.Style.yellow ++ "▸" ++ ui.Style.reset,
        };
    }

    pub fn render(self: *ListView, term: *Terminal) void {
        term.clear();
        term.moveTo(0, 0);

        // Header
        ui.print("{s}PR Review Feedback{s}\n", .{ ui.Style.bold, ui.Style.reset });
        ui.print("{s}j/k: navigate  Enter: expand  c/y: copy+LLM  C: copy raw  q: quit{s}\n\n", .{ ui.Style.dim, ui.Style.reset });

        if (self.items.len == 0) {
            ui.print("{s}No feedback items.{s}\n", .{ ui.Style.dim, ui.Style.reset });
            return;
        }

        const start = self.scroll_offset;
        const end = @min(start + self.visible_height, self.items.len);

        for (self.items[start..end], start..) |item, i| {
            const is_selected = i == self.selected;
            const icon = getTypeIcon(item.item_type);
            const selector = if (is_selected) ui.Style.blue ++ ui.Style.arrow ++ ui.Style.reset else "  ";

            if (is_selected) {
                ui.print(" {s} {s} {s}{s}{s}\n", .{
                    selector,
                    icon,
                    ui.Style.bold,
                    item.primary,
                    ui.Style.reset,
                });
            } else {
                ui.print(" {s} {s} {s}\n", .{
                    selector,
                    icon,
                    item.primary,
                });
            }

            if (item.secondary) |sec| {
                ui.print("        {s}{s}{s}\n", .{ ui.Style.dim, sec, ui.Style.reset });
            }

            // Show expanded detail for selected item
            if (is_selected and self.expanded) {
                if (item.detail) |detail| {
                    ui.print("\n", .{});
                    ui.print("        {s}───────────────────────────────────────{s}\n", .{ ui.Style.dim, ui.Style.reset });
                    // Print detail with some indentation
                    var lines = std.mem.splitScalar(u8, detail, '\n');
                    while (lines.next()) |line| {
                        ui.print("        {s}\n", .{line});
                    }
                    ui.print("        {s}───────────────────────────────────────{s}\n", .{ ui.Style.dim, ui.Style.reset });
                    ui.print("\n", .{});
                }
            }
        }

        // Footer with scroll indicator
        ui.print("\n", .{});
        if (self.items.len > self.visible_height) {
            ui.print("{s}[{d}/{d}]{s}\n", .{
                ui.Style.dim,
                self.selected + 1,
                self.items.len,
                ui.Style.reset,
            });
        }
    }
};

/// Run an interactive TUI loop with the given list items
/// Returns the action taken and the selected item index
pub const Action = enum {
    quit,
    copy_raw,
    copy_llm,
};

pub fn runInteractive(allocator: std.mem.Allocator, items: []const ListItem) !struct { action: Action, selected: usize } {
    _ = allocator;

    var term = try Terminal.init();
    defer term.deinit();

    // Calculate visible height (leave room for header and footer)
    const size = try term.getSize();
    const visible_height = if (size.height > 8) size.height - 8 else 10;

    var list = ListView.init(items, visible_height);

    try term.enterRawMode();
    defer term.exitRawMode();

    while (true) {
        list.render(&term);

        const key = try term.readKey();
        switch (key) {
            .up => list.moveUp(),
            .down => list.moveDown(),
            .enter => list.toggleExpanded(),
            .escape, .ctrl_c, .ctrl_d => {
                return .{ .action = .quit, .selected = list.selected };
            },
            .char => |c| {
                if (c == 'k') {
                    list.moveUp();
                } else if (c == 'j') {
                    list.moveDown();
                } else if (c == 'c' or c == 'y') {
                    return .{ .action = .copy_llm, .selected = list.selected };
                } else if (c == 'C') {
                    return .{ .action = .copy_raw, .selected = list.selected };
                } else if (c == 'q') {
                    return .{ .action = .quit, .selected = list.selected };
                }
            },
            else => {},
        }
    }
}
