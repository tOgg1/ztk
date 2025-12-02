const std = @import("std");
const ui = @import("ui.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const stack = @import("stack.zig");
const github = @import("github.zig");

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
    ui.print("  {s}Stack:{s} {s}  ({d} commit{s} ahead of {s})\n", .{
        ui.Style.bold,
        ui.Style.reset,
        stk.head_branch,
        stk.commits.len,
        if (stk.commits.len == 1) "" else "s",
        stk.base_branch,
    });
    ui.print("\n", .{});

    var i: usize = stk.commits.len;
    while (i > 0) {
        i -= 1;
        const commit = stk.commits[i];
        const is_current = i == stk.commits.len - 1;
        const icon = if (is_current) ui.Style.current else ui.Style.other;
        const marker = if (is_current) ui.Style.dim ++ " " ++ ui.Style.arrow ++ " you are here" ++ ui.Style.reset else "";

        if (commit.is_wip) {
            ui.print("  {s}{s}{s} {s}  {s}[WIP]{s}{s}\n", .{
                ui.Style.yellow,
                icon,
                ui.Style.reset,
                commit.title,
                ui.Style.yellow,
                ui.Style.reset,
                marker,
            });
        } else {
            ui.print("  {s}{s}{s} {s}{s}\n", .{
                if (is_current) ui.Style.bold else "",
                icon,
                ui.Style.reset,
                commit.title,
                marker,
            });
        }
        ui.print("  {s}   {s}{s}\n", .{ ui.Style.pipe, ui.Style.dim, commit.short_sha });
        ui.print("  {s}{s}\n", .{ ui.Style.pipe, ui.Style.reset });
    }

    ui.print("  {s}{s}{s} {s}\n", .{ ui.Style.dim, ui.Style.other, ui.Style.reset, stk.base_branch });
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
        ui.print("No commits to sync.\n", .{});
        return;
    }

    var gh_client = github.Client.init(allocator, cfg) catch |err| {
        switch (err) {
            github.GitHubError.NoToken => {
                ui.printError("GitHub authentication failed.\n", .{});
                ui.print("  Run 'gh auth login' or set GITHUB_TOKEN.\n", .{});
            },
            else => {
                ui.printError("Failed to initialize GitHub client: {any}\n", .{err});
            },
        }
        return;
    };
    defer gh_client.deinit();

    ui.print("\n", .{});
    ui.print("  {s}Syncing stack to GitHub...{s}\n", .{ ui.Style.bold, ui.Style.reset });
    ui.print("\n", .{});

    var created_count: usize = 0;
    var updated_count: usize = 0;
    var skipped_count: usize = 0;
    var prev_branch: ?[]const u8 = null;

    for (stk.commits) |commit| {
        if (commit.is_wip) {
            ui.print("  {s}{s}{s} {s}  {s}[WIP skipped]{s}\n", .{
                ui.Style.yellow,
                ui.Style.other,
                ui.Style.reset,
                commit.title,
                ui.Style.dim,
                ui.Style.reset,
            });
            skipped_count += 1;
            continue;
        }

        var branch_buf: [256]u8 = undefined;
        const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
            stk.head_branch,
            commit.short_sha,
        }) catch {
            ui.printError("Branch name too long\n", .{});
            continue;
        };

        const base_ref = prev_branch orelse cfg.main_branch;

        ui.print("  {s}{s}{s} {s}\n", .{
            ui.Style.blue,
            ui.Style.other,
            ui.Style.reset,
            commit.title,
        });

        ui.print("  {s}{s}{s}   {s}Branch: {s}{s}\n", .{
            ui.Style.dim,
            ui.Style.pipe,
            ui.Style.reset,
            ui.Style.dim,
            branch_name,
            ui.Style.reset,
        });

        git.ensureBranchAt(allocator, branch_name, commit.sha) catch {
            ui.printError("    Failed to create branch\n", .{});
            continue;
        };

        ui.print("  {s}{s}{s}   {s}Pushing...{s}", .{
            ui.Style.dim,
            ui.Style.pipe,
            ui.Style.reset,
            ui.Style.dim,
            ui.Style.reset,
        });

        git.push(allocator, cfg.remote, branch_name, true) catch {
            ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
            continue;
        };
        ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });

        const existing_pr = gh_client.findPR(branch_name) catch null;

        if (existing_pr) |pr| {
            ui.print("  {s}{s}{s}   {s}PR #{d} updated{s}\n", .{
                ui.Style.dim,
                ui.Style.pipe,
                ui.Style.reset,
                ui.Style.dim,
                pr.number,
                ui.Style.reset,
            });
            gh_client.updatePR(pr.number, commit.title, commit.body, base_ref) catch {
                ui.printError("    Failed to update PR\n", .{});
            };
            updated_count += 1;
            var mutable_pr = pr;
            mutable_pr.deinit(allocator);
        } else {
            ui.print("  {s}{s}{s}   {s}Creating PR...{s}", .{
                ui.Style.dim,
                ui.Style.pipe,
                ui.Style.reset,
                ui.Style.dim,
                ui.Style.reset,
            });

            const new_pr = gh_client.createPR(branch_name, base_ref, commit.title, commit.body) catch {
                ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
                continue;
            };
            ui.print(" {s}done{s} {s}→ #{d}{s}\n", .{
                ui.Style.green,
                ui.Style.reset,
                ui.Style.blue,
                new_pr.number,
                ui.Style.reset,
            });
            created_count += 1;
            var mutable_pr = new_pr;
            mutable_pr.deinit(allocator);
        }

        ui.print("  {s}{s}{s}\n", .{ ui.Style.dim, ui.Style.pipe, ui.Style.reset });

        if (prev_branch) |pb| allocator.free(pb);
        prev_branch = allocator.dupe(u8, branch_name) catch null;
    }

    if (prev_branch) |pb| allocator.free(pb);

    ui.print("\n", .{});
    ui.print("  {s}{s} Stack synced:{s} ", .{ ui.Style.green, ui.Style.check, ui.Style.reset });

    const total = created_count + updated_count;
    ui.print("{d} PR{s}", .{ total, if (total == 1) "" else "s" });

    if (created_count > 0) {
        ui.print(" ({s}{d} created{s}", .{ ui.Style.green, created_count, ui.Style.reset });
        if (updated_count > 0) {
            ui.print(", {d} updated", .{updated_count});
        }
        ui.print(")", .{});
    } else if (updated_count > 0) {
        ui.print(" ({d} updated)", .{updated_count});
    }

    if (skipped_count > 0) {
        ui.print(", {s}{d} WIP skipped{s}", .{ ui.Style.yellow, skipped_count, ui.Style.reset });
    }

    ui.print("\n\n", .{});
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
