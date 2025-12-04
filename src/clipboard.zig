const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");

pub const ClipboardError = error{
    NotSupported,
    CommandFailed,
    OutOfMemory,
};

/// Copy text to system clipboard
/// Uses platform-specific commands: pbcopy (macOS), wl-copy/xclip (Linux)
pub fn copy(allocator: std.mem.Allocator, text: []const u8) ClipboardError!void {
    if (builtin.os.tag == .macos) {
        return copyViaPbcopy(allocator, text);
    } else if (builtin.os.tag == .linux) {
        return copyViaLinux(allocator, text);
    } else {
        return ClipboardError.NotSupported;
    }
}

fn copyViaPbcopy(allocator: std.mem.Allocator, text: []const u8) ClipboardError!void {
    var child = std.process.Child.init(&.{"pbcopy"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return ClipboardError.CommandFailed;

    if (child.stdin) |stdin| {
        stdin.writeAll(text) catch return ClipboardError.CommandFailed;
        stdin.close();
        child.stdin = null;
    }

    const result = child.wait() catch return ClipboardError.CommandFailed;
    if (result.Exited != 0) {
        return ClipboardError.CommandFailed;
    }
}

fn copyViaLinux(allocator: std.mem.Allocator, text: []const u8) ClipboardError!void {
    // Try wl-copy first (Wayland)
    if (copyViaCommand(allocator, &.{"wl-copy"}, text)) {
        return;
    } else |_| {}

    // Fallback to xclip (X11)
    if (copyViaCommand(allocator, &.{ "xclip", "-selection", "clipboard" }, text)) {
        return;
    } else |_| {}

    // Fallback to xsel
    if (copyViaCommand(allocator, &.{ "xsel", "--clipboard", "--input" }, text)) {
        return;
    } else |_| {}

    return ClipboardError.NotSupported;
}

fn copyViaCommand(allocator: std.mem.Allocator, argv: []const []const u8, text: []const u8) ClipboardError!void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return ClipboardError.CommandFailed;

    if (child.stdin) |stdin| {
        stdin.writeAll(text) catch return ClipboardError.CommandFailed;
        stdin.close();
        child.stdin = null;
    }

    const result = child.wait() catch return ClipboardError.CommandFailed;
    if (result.Exited != 0) {
        return ClipboardError.CommandFailed;
    }
}

/// Copy text to clipboard with user feedback
/// Falls back to printing if clipboard not available
pub fn copyWithFeedback(allocator: std.mem.Allocator, text: []const u8) void {
    copy(allocator, text) catch |err| {
        switch (err) {
            ClipboardError.NotSupported => {
                ui.printWarning("Clipboard not available. Here's the text:\n\n", .{});
                ui.print("{s}\n", .{text});
            },
            ClipboardError.CommandFailed => {
                ui.printError("Failed to copy to clipboard. Here's the text:\n\n", .{});
                ui.print("{s}\n", .{text});
            },
            else => {
                ui.printError("Clipboard error. Here's the text:\n\n", .{});
                ui.print("{s}\n", .{text});
            },
        }
        return;
    };
    ui.printSuccess("Copied to clipboard!\n", .{});
}
