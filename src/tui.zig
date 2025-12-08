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

    /// Enter raw mode without clearing screen (for inline TUI components)
    /// Unlike enterRawMode, this keeps OPOST enabled so \n is translated to \r\n
    pub fn enterRawModeInline(self: *Terminal) !void {
        var raw = self.original_termios;

        // Disable echo, canonical mode, signals, extended input processing
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Disable software flow control, CR-to-NL on input
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Keep OPOST enabled for inline mode - allows \n to work normally
        // (unlike full raw mode which disables it for precise cursor control)

        // Set character size to 8 bits
        raw.cflag.CSIZE = .CS8;

        // Minimum bytes for read, timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(self.tty.handle, .FLUSH, raw);
        self.in_raw_mode = true;

        // Hide cursor but don't clear screen
        self.hideCursor();
    }

    /// Exit raw mode for inline components (shows cursor, restores settings)
    pub fn exitRawModeInline(self: *Terminal) void {
        self.showCursor();
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

/// Callback function type for copy operations
pub const CopyCallback = *const fn (selected: usize, copy_llm: bool) void;

/// Callback function type for opening URLs
pub const OpenCallback = *const fn (url: []const u8) void;

/// PR info for multi-PR navigation
pub const PRInfo = struct {
    number: u32,
    title: []const u8,
    url: []const u8,
};

/// Run an interactive TUI loop with the given list items
/// The copy_callback is called when user presses c/y/C, allowing copy without exiting
/// The open_callback is called when user presses o to open the current PR in browser
/// If prs is provided with multiple PRs, left/right navigation switches between them
/// and pr_change_callback is called when the user navigates to a different PR
pub fn runInteractive(
    allocator: std.mem.Allocator,
    items: []const ListItem,
    copy_callback: ?CopyCallback,
    open_callback: ?OpenCallback,
    prs: ?[]const PRInfo,
    current_pr_index: *usize,
    pr_change_callback: ?*const fn (allocator: std.mem.Allocator, pr_index: usize) ?[]const ListItem,
) !void {
    var term = try Terminal.init();
    defer term.deinit();

    // Calculate visible height (leave room for header and footer)
    const size = try term.getSize();
    const visible_height = if (size.height > 10) size.height - 10 else 8;

    var current_items = items;
    var list = ListView.init(current_items, visible_height);

    // Status message for feedback
    var status_msg: ?[]const u8 = null;
    var status_is_error = false;

    try term.enterRawMode();
    defer term.exitRawMode();

    while (true) {
        renderWithPRNav(&list, &term, prs, current_pr_index.*, status_msg, status_is_error);

        // Clear status after showing it
        status_msg = null;
        status_is_error = false;

        const key = try term.readKey();
        switch (key) {
            .up => list.moveUp(),
            .down => list.moveDown(),
            .left => {
                // Navigate to previous PR
                if (prs != null and current_pr_index.* > 0 and pr_change_callback != null) {
                    current_pr_index.* -= 1;
                    if (pr_change_callback.?(allocator, current_pr_index.*)) |new_items| {
                        current_items = new_items;
                        list = ListView.init(current_items, visible_height);
                    }
                }
            },
            .right => {
                // Navigate to next PR
                if (prs) |pr_list| {
                    if (current_pr_index.* + 1 < pr_list.len and pr_change_callback != null) {
                        current_pr_index.* += 1;
                        if (pr_change_callback.?(allocator, current_pr_index.*)) |new_items| {
                            current_items = new_items;
                            list = ListView.init(current_items, visible_height);
                        }
                    }
                }
            },
            .enter => list.toggleExpanded(),
            .escape, .ctrl_c, .ctrl_d => {
                return;
            },
            .char => |c| {
                if (c == 'k') {
                    list.moveUp();
                } else if (c == 'j') {
                    list.moveDown();
                } else if (c == 'h') {
                    // Navigate to previous PR (vim-style)
                    if (prs != null and current_pr_index.* > 0 and pr_change_callback != null) {
                        current_pr_index.* -= 1;
                        if (pr_change_callback.?(allocator, current_pr_index.*)) |new_items| {
                            current_items = new_items;
                            list = ListView.init(current_items, visible_height);
                        }
                    }
                } else if (c == 'l') {
                    // Navigate to next PR (vim-style)
                    if (prs) |pr_list| {
                        if (current_pr_index.* + 1 < pr_list.len and pr_change_callback != null) {
                            current_pr_index.* += 1;
                            if (pr_change_callback.?(allocator, current_pr_index.*)) |new_items| {
                                current_items = new_items;
                                list = ListView.init(current_items, visible_height);
                            }
                        }
                    }
                } else if (c == 'c' or c == 'y') {
                    if (copy_callback) |cb| {
                        cb(list.selected, true);
                        status_msg = "Copied to clipboard (LLM format)";
                    }
                } else if (c == 'C') {
                    if (copy_callback) |cb| {
                        cb(list.selected, false);
                        status_msg = "Copied to clipboard (raw)";
                    }
                } else if (c == 'o') {
                    // Open current PR in browser
                    if (prs) |pr_list| {
                        if (current_pr_index.* < pr_list.len) {
                            if (open_callback) |cb| {
                                cb(pr_list[current_pr_index.*].url);
                                status_msg = "Opening PR in browser...";
                            }
                        }
                    }
                } else if (c == 'q') {
                    return;
                }
            },
            else => {},
        }
    }
}

/// Select from a list of items with inline display (no screen clear)
/// Returns the selected index, or null if cancelled
pub fn selectFromList(title: []const u8, items: []const []const u8) !?usize {
    if (items.len == 0) return null;

    const stdout = std.posix.STDOUT_FILENO;
    var term = try Terminal.init();
    defer term.deinit();

    var selected: usize = 0;
    const max_visible: usize = 10; // Show at most 10 items at a time
    var scroll_offset: usize = 0;

    // Enter raw mode (without clearing screen)
    try term.enterRawModeInline();
    defer term.exitRawModeInline();

    // Initial render
    renderSelectList(title, items, selected, scroll_offset, max_visible);

    while (true) {
        const key = try term.readKey();
        var needs_redraw = false;

        switch (key) {
            .up => {
                if (selected > 0) {
                    selected -= 1;
                    if (selected < scroll_offset) {
                        scroll_offset = selected;
                    }
                    needs_redraw = true;
                }
            },
            .down => {
                if (selected + 1 < items.len) {
                    selected += 1;
                    if (selected >= scroll_offset + max_visible) {
                        scroll_offset = selected - max_visible + 1;
                    }
                    needs_redraw = true;
                }
            },
            .enter => {
                // Move cursor to end and print selection confirmation
                _ = std.posix.write(stdout, "\n") catch {};
                return selected;
            },
            .escape, .ctrl_c, .ctrl_d => {
                // Move cursor to end
                _ = std.posix.write(stdout, "\n") catch {};
                return null;
            },
            .char => |c| {
                if (c == 'k' and selected > 0) {
                    selected -= 1;
                    if (selected < scroll_offset) {
                        scroll_offset = selected;
                    }
                    needs_redraw = true;
                } else if (c == 'j' and selected + 1 < items.len) {
                    selected += 1;
                    if (selected >= scroll_offset + max_visible) {
                        scroll_offset = selected - max_visible + 1;
                    }
                    needs_redraw = true;
                } else if (c == 'q') {
                    _ = std.posix.write(stdout, "\n") catch {};
                    return null;
                }
            },
            else => {},
        }

        if (needs_redraw) {
            // Move cursor up to beginning of list and redraw
            const visible = @min(items.len, max_visible);
            var buf: [32]u8 = undefined;
            const up_seq = std.fmt.bufPrint(&buf, "\x1b[{d}A\r", .{visible + 2}) catch continue;
            _ = std.posix.write(stdout, up_seq) catch {};
            renderSelectList(title, items, selected, scroll_offset, max_visible);
        }
    }
}

fn renderSelectList(title: []const u8, items: []const []const u8, selected: usize, scroll_offset: usize, max_visible: usize) void {
    const stdout = std.posix.STDOUT_FILENO;

    // Title
    ui.print("{s}{s}{s}\n", .{ ui.Style.bold, title, ui.Style.reset });

    // Hint
    ui.print("{s}↑/↓/j/k: navigate  Enter: select  q/Esc: cancel{s}\n", .{ ui.Style.dim, ui.Style.reset });

    // Items
    const end = @min(scroll_offset + max_visible, items.len);
    for (items[scroll_offset..end], scroll_offset..) |item, i| {
        // Clear line first
        _ = std.posix.write(stdout, "\x1b[2K") catch {};

        const is_selected = i == selected;
        if (is_selected) {
            ui.print("  {s}{s}{s} {s}{s}{s}\n", .{
                ui.Style.blue,
                ui.Style.arrow_right,
                ui.Style.reset,
                ui.Style.bold,
                item,
                ui.Style.reset,
            });
        } else {
            ui.print("    {s}\n", .{item});
        }
    }

    // Scroll indicator if needed
    _ = std.posix.write(stdout, "\x1b[2K") catch {};
    if (items.len > max_visible) {
        ui.print("{s}[{d}/{d}]{s}", .{
            ui.Style.dim,
            selected + 1,
            items.len,
            ui.Style.reset,
        });
    }
}

/// Confirm with a yes/no prompt (inline, single keypress)
/// Returns true for yes, false for no/cancel
pub fn confirm(prompt_text: []const u8) !bool {
    var term = try Terminal.init();
    defer term.deinit();

    // Print prompt
    ui.print("{s} {s}[y/N]{s} ", .{ prompt_text, ui.Style.dim, ui.Style.reset });

    // Enter raw mode for single keypress
    try term.enterRawModeInline();
    defer term.exitRawModeInline();

    const key = try term.readKey();

    // Print newline after response
    ui.print("\n", .{});

    return switch (key) {
        .char => |c| c == 'y' or c == 'Y',
        else => false,
    };
}

fn renderWithPRNav(list: *ListView, term: *Terminal, prs: ?[]const PRInfo, current_pr_index: usize, status_msg: ?[]const u8, status_is_error: bool) void {
    term.clear();
    term.moveTo(0, 0);

    // Header with PR navigation if multiple PRs
    if (prs) |pr_list| {
        if (pr_list.len > 1) {
            const current_pr = pr_list[current_pr_index];
            ui.print("{s}PR #{d}: {s}{s}\n", .{
                ui.Style.bold,
                current_pr.number,
                current_pr.title,
                ui.Style.reset,
            });
            ui.print("{s}← h/l →: switch PR ({d}/{d})  ", .{
                ui.Style.dim,
                current_pr_index + 1,
                pr_list.len,
            });
            ui.print("j/k: navigate  Enter: expand  c/y: copy+LLM  C: copy raw  q: quit{s}\n\n", .{ui.Style.reset});
        } else if (pr_list.len == 1) {
            const current_pr = pr_list[0];
            ui.print("{s}PR #{d}: {s}{s}\n", .{
                ui.Style.bold,
                current_pr.number,
                current_pr.title,
                ui.Style.reset,
            });
            ui.print("{s}j/k: navigate  Enter: expand  c/y: copy+LLM  C: copy raw  q: quit{s}\n\n", .{ ui.Style.dim, ui.Style.reset });
        }
    } else {
        ui.print("{s}PR Review Feedback{s}\n", .{ ui.Style.bold, ui.Style.reset });
        ui.print("{s}j/k: navigate  Enter: expand  c/y: copy+LLM  C: copy raw  q: quit{s}\n\n", .{ ui.Style.dim, ui.Style.reset });
    }

    if (list.items.len == 0) {
        ui.print("{s}No feedback items.{s}\n", .{ ui.Style.dim, ui.Style.reset });
        return;
    }

    const start = list.scroll_offset;
    const end = @min(start + list.visible_height, list.items.len);

    for (list.items[start..end], start..) |item, i| {
        const is_selected = i == list.selected;
        const icon = ListView.getTypeIcon(item.item_type);
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
        if (is_selected and list.expanded) {
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

    // Footer with scroll indicator and status
    ui.print("\n", .{});
    if (list.items.len > list.visible_height) {
        ui.print("{s}[{d}/{d}]{s}", .{
            ui.Style.dim,
            list.selected + 1,
            list.items.len,
            ui.Style.reset,
        });
    }

    // Show status message if present
    if (status_msg) |msg| {
        if (status_is_error) {
            ui.print("  {s}{s}{s}", .{ ui.Style.red, msg, ui.Style.reset });
        } else {
            ui.print("  {s}{s}{s}", .{ ui.Style.green, msg, ui.Style.reset });
        }
    }
    ui.print("\n", .{});
}
