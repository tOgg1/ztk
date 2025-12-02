const std = @import("std");
const ui = @import("ui.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const stack = @import("stack.zig");

pub const Command = enum {
    init,
    status,
    update,
    help,

    pub fn fromString(str: []const u8) ?Command {
        const commands = std.StaticStringMap(Command).initComptime(.{
            .{ "init", .init },
            .{ "status", .status },
            .{ "s", .status },
            .{ "st", .status },
            .{ "update", .update },
            .{ "u", .update },
            .{ "up", .update },
            .{ "help", .help },
            .{ "--help", .help },
            .{ "-h", .help },
        });
        return commands.get(str);
    }
};

pub fn handleCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd_str = args[1];

    if (Command.fromString(cmd_str)) |cmd| {
        switch (cmd) {
            .init => cmdInit(allocator),
            .status => cmdStatus(allocator),
            .update => cmdUpdate(allocator),
            .help => printUsage(),
        }
    } else {
        ui.printError("Unknown command: {s}\n", .{cmd_str});
        ui.print("\n", .{});
        printUsage();
    }
}

fn cmdInit(allocator: std.mem.Allocator) void {
    if (config.configExists(allocator)) {
        ui.print("ztk is already initialized in this repository.\n", .{});
        return;
    }

    const remote_url = git.getRemoteUrl(allocator, "origin") catch {
        ui.printError("Could not get remote URL. Make sure you're in a git repository with an 'origin' remote.\n", .{});
        return;
    };
    defer allocator.free(remote_url);

    var repo_info = git.parseGitHubRemote(allocator, remote_url) catch {
        ui.printError("Could not parse GitHub remote URL: {s}\n", .{remote_url});
        return;
    };
    defer repo_info.deinit(allocator);

    config.initDefault(allocator, repo_info.owner, repo_info.repo) catch |err| {
        ui.printError("Failed to create config: {any}\n", .{err});
        return;
    };

    ui.printSuccess("Initialized ztk for {s}/{s}\n", .{ repo_info.owner, repo_info.repo });
    ui.print("  Created .ztk.json\n", .{});
}

fn cmdStatus(allocator: std.mem.Allocator) void {
    const cfg = config.load(allocator) catch |err| {
        switch (err) {
            config.ConfigError.ConfigNotFound => {
                ui.printError("Not initialized. Run 'ztk init' first.\n", .{});
            },
            config.ConfigError.NotInGitRepo => {
                ui.printError("Not in a git repository.\n", .{});
            },
            else => {
                ui.printError("Failed to load config: {any}\n", .{err});
            },
        }
        return;
    };
    defer {
        var c = cfg;
        c.deinit(allocator);
    }

    const stk = stack.readStack(allocator, cfg) catch |err| {
        ui.printError("Failed to read stack: {any}\n", .{err});
        return;
    };
    defer {
        var s = stk;
        s.deinit(allocator);
    }

    if (stk.commits.len == 0) {
        ui.print("No commits ahead of {s}\n", .{cfg.main_branch});
        return;
    }

    ui.print("\n", .{});
    ui.print("  {s}Stack:{s} {s}{s}{s}  {s}({d} commit{s} ahead of {s}){s}\n", .{
        ui.Style.bold,
        ui.Style.reset,
        ui.Style.blue,
        stk.head_branch,
        ui.Style.reset,
        ui.Style.dim,
        stk.commits.len,
        if (stk.commits.len == 1) "" else "s",
        stk.base_branch,
        ui.Style.reset,
    });
    ui.print("\n", .{});

    var i: usize = stk.commits.len;
    while (i > 0) {
        i -= 1;
        const commit = stk.commits[i];
        const is_current = i == stk.commits.len - 1;
        const marker = if (is_current) ui.Style.dim ++ " " ++ ui.Style.arrow ++ " you are here" ++ ui.Style.reset else "";

        if (commit.is_wip) {
            ui.print("  {s}{s}{s} {s}  {s}[WIP]{s}{s}\n", .{
                ui.Style.yellow,
                ui.Style.current,
                ui.Style.reset,
                commit.title,
                ui.Style.yellow,
                ui.Style.reset,
                marker,
            });
        } else if (is_current) {
            ui.print("  {s}{s}{s} {s}{s}{s}{s}\n", .{
                ui.Style.green,
                ui.Style.current,
                ui.Style.reset,
                ui.Style.bold,
                commit.title,
                ui.Style.reset,
                marker,
            });
        } else {
            ui.print("  {s}{s}{s} {s}\n", .{
                ui.Style.blue,
                ui.Style.other,
                ui.Style.reset,
                commit.title,
            });
        }
        ui.print("  {s}{s}{s}   {s}{s}\n", .{ ui.Style.dim, ui.Style.pipe, ui.Style.reset, ui.Style.dim, commit.short_sha });
        ui.print("  {s}{s}{s}\n", .{ ui.Style.dim, ui.Style.pipe, ui.Style.reset });
    }

    ui.print("  {s}{s}{s} {s}{s}{s}\n", .{ ui.Style.dim, ui.Style.other, ui.Style.reset, ui.Style.dim, stk.base_branch, ui.Style.reset });
    ui.print("\n", .{});

    var wip_count: usize = 0;
    for (stk.commits) |c| {
        if (c.is_wip) wip_count += 1;
    }

    ui.print("  Summary: {d} commit{s}", .{ stk.commits.len, if (stk.commits.len == 1) "" else "s" });
    if (wip_count > 0) {
        ui.print(", {s}{d} WIP{s}", .{ ui.Style.yellow, wip_count, ui.Style.reset });
    }
    ui.print("\n\n", .{});
}

fn cmdUpdate(allocator: std.mem.Allocator) void {
    _ = allocator;
    ui.print("ztk update: not implemented\n", .{});
}

fn printUsage() void {
    const usage =
        \\ztk - Stacked Pull Requests on GitHub
        \\
        \\USAGE:
        \\    ztk <command> [options]
        \\
        \\COMMANDS:
        \\    init              Initialize ztk in the current repository
        \\    status, s, st     Show status of the current stack
        \\    update, u, up     Create/update pull requests for commits in the stack
        \\    help, --help, -h  Show this help message
        \\
        \\EXAMPLES:
        \\    ztk init          # Initialize ztk config
        \\    ztk status        # Show stack status
        \\    ztk update        # Sync stack to GitHub
        \\
    ;
    ui.print("{s}", .{usage});
}
