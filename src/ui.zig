const std = @import("std");

pub const Style = struct {
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const blue = "\x1b[34m";
    pub const dim = "\x1b[2m";
    pub const bold = "\x1b[1m";
    pub const reset = "\x1b[0m";

    pub const current = "◉";
    pub const other = "◯";
    pub const check = "✓";
    pub const cross = "✗";
    pub const pending = "⏳";
    pub const warning = "⚠";
    pub const arrow = "←";
    pub const pipe = "│";
};

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.posix.STDOUT_FILENO;
    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.write(stdout, output) catch {};
}

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.posix.STDERR_FILENO;
    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, Style.red ++ "error: " ++ Style.reset ++ fmt, args) catch return;
    _ = std.posix.write(stderr, output) catch {};
}

pub fn printSuccess(comptime fmt: []const u8, args: anytype) void {
    print(Style.green ++ Style.check ++ " " ++ Style.reset ++ fmt, args);
}

pub fn printWarning(comptime fmt: []const u8, args: anytype) void {
    print(Style.yellow ++ Style.warning ++ " " ++ Style.reset ++ fmt, args);
}
