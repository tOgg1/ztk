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
    merge,
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
            .{ "merge", .merge },
            .{ "m", .merge },
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
            .merge => cmdMerge(allocator, args),
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

    var gh_client: ?github.Client = github.Client.init(allocator, cfg) catch null;
    defer if (gh_client) |*client| client.deinit();

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

    var wip_count: usize = 0;
    var merged_count: usize = 0;

    var i: usize = stk.commits.len;
    while (i > 0) {
        i -= 1;
        const commit = stk.commits[i];
        const is_current = i == stk.commits.len - 1;
        const marker = if (is_current) ui.Style.dim ++ " " ++ ui.Style.arrow ++ " you are here" ++ ui.Style.reset else "";

        var branch_buf: [256]u8 = undefined;
        const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
            stk.head_branch,
            commit.short_sha,
        }) catch "";

        const is_merged = if (gh_client) |*client| client.isPRMergedOrClosed(branch_name) else false;

        if (is_merged) {
            merged_count += 1;
            ui.print("  {s}{s} {s}  [merged]{s}{s}\n", .{
                ui.Style.dim,
                ui.Style.other,
                commit.title,
                ui.Style.reset,
                marker,
            });
        } else if (commit.is_wip) {
            wip_count += 1;
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

    ui.print("  Summary: {d} commit{s}", .{ stk.commits.len, if (stk.commits.len == 1) "" else "s" });
    if (merged_count > 0) {
        ui.print(", {s}{d} merged{s}", .{ ui.Style.dim, merged_count, ui.Style.reset });
    }
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
    var wip_count: usize = 0;
    var merged_count: usize = 0;
    var prev_branch: ?[]const u8 = null;

    for (stk.commits) |commit| {
        if (commit.is_wip) {
            ui.print("  {s}{s}{s} {s}  {s}[WIP]{s}\n", .{
                ui.Style.yellow,
                ui.Style.other,
                ui.Style.reset,
                commit.title,
                ui.Style.dim,
                ui.Style.reset,
            });
            wip_count += 1;
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

        if (gh_client.isPRMergedOrClosed(branch_name)) {
            ui.print("  {s}{s}{s} {s}  {s}[merged]{s}\n", .{
                ui.Style.dim,
                ui.Style.other,
                ui.Style.reset,
                commit.title,
                ui.Style.dim,
                ui.Style.reset,
            });
            merged_count += 1;
            continue;
        }

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

    if (merged_count > 0) {
        ui.print(", {s}{d} already merged{s}", .{ ui.Style.dim, merged_count, ui.Style.reset });
    }
    if (wip_count > 0) {
        ui.print(", {s}{d} WIP{s}", .{ ui.Style.yellow, wip_count, ui.Style.reset });
    }

    ui.print("\n\n", .{});
}

fn cmdMerge(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    var auto_rebase = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "-ar") or std.mem.eql(u8, arg, "--auto-rebase")) {
            auto_rebase = true;
        }
    }

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
        ui.print("No commits to merge.\n", .{});
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
    ui.print("  {s}Checking PRs for merge...{s}\n", .{ ui.Style.bold, ui.Style.reset });
    ui.print("\n", .{});

    const PRInfo = struct {
        number: u32,
        title: []const u8,
        branch_name: []const u8,
        mergeable: bool,
        approved: bool,
    };

    var pr_infos = std.ArrayListUnmanaged(PRInfo){};
    defer {
        for (pr_infos.items) |info| {
            allocator.free(info.branch_name);
        }
        pr_infos.deinit(allocator);
    }

    for (stk.commits) |commit| {
        if (commit.is_wip) continue;

        var branch_buf: [256]u8 = undefined;
        const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
            stk.head_branch,
            commit.short_sha,
        }) catch continue;

        const pr = gh_client.findPR(branch_name) catch continue;
        if (pr) |found_pr| {
            const status = gh_client.getPRStatus(found_pr.number) catch {
                var mutable_pr = found_pr;
                mutable_pr.deinit(allocator);
                continue;
            };

            const branch_copy = allocator.dupe(u8, branch_name) catch continue;

            pr_infos.append(allocator, .{
                .number = found_pr.number,
                .title = commit.title,
                .branch_name = branch_copy,
                .mergeable = status.mergeable,
                .approved = status.approved,
            }) catch {
                allocator.free(branch_copy);
                var mutable_pr = found_pr;
                mutable_pr.deinit(allocator);
                continue;
            };

            var mutable_pr = found_pr;
            mutable_pr.deinit(allocator);
        }
    }

    if (pr_infos.items.len == 0) {
        ui.print("  No PRs found. Run 'ztk update' first.\n", .{});
        ui.print("\n", .{});
        return;
    }

    var mergeable_count: usize = 0;
    for (pr_infos.items) |info| {
        const status_icon = if (info.mergeable) ui.Style.check else ui.Style.cross;
        const status_color = if (info.mergeable) ui.Style.green else ui.Style.red;
        const approved_str = if (info.approved) ui.Style.green ++ ui.Style.check ++ " Approved" ++ ui.Style.reset else ui.Style.dim ++ "Needs review" ++ ui.Style.reset;

        ui.print("  {s}{s}{s} #{d} {s}\n", .{
            status_color,
            status_icon,
            ui.Style.reset,
            info.number,
            info.title,
        });
        ui.print("     {s} · {s}\n", .{
            if (info.mergeable) ui.Style.green ++ "Mergeable" ++ ui.Style.reset else ui.Style.red ++ "Not mergeable" ++ ui.Style.reset,
            approved_str,
        });

        if (info.mergeable) {
            mergeable_count += 1;
        } else {
            break;
        }
    }

    ui.print("\n", .{});

    if (mergeable_count == 0) {
        ui.print("  {s}{s} No PRs ready to merge{s}\n", .{ ui.Style.yellow, ui.Style.warning, ui.Style.reset });
        ui.print("\n", .{});
        return;
    }

    const top_pr = pr_infos.items[mergeable_count - 1];

    ui.print("  {s}Merging {d} commit{s} via PR #{d}...{s}\n", .{
        ui.Style.bold,
        mergeable_count,
        if (mergeable_count == 1) "" else "s",
        top_pr.number,
        ui.Style.reset,
    });
    ui.print("\n", .{});

    ui.print("  Updating #{d} base to {s}...", .{ top_pr.number, cfg.main_branch });
    gh_client.updatePR(top_pr.number, null, null, cfg.main_branch) catch {
        ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
        return;
    };
    ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });

    ui.print("  Merging #{d} {s}...", .{ top_pr.number, top_pr.title });
    gh_client.mergePR(top_pr.number) catch {
        ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
        return;
    };
    ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });

    gh_client.deleteBranch(top_pr.branch_name) catch {};

    if (mergeable_count > 1) {
        ui.print("\n", .{});
        ui.print("  Closing {d} merged PR{s}...\n", .{ mergeable_count - 1, if (mergeable_count == 2) "" else "s" });

        for (pr_infos.items[0 .. mergeable_count - 1]) |info| {
            var comment_buf: [512]u8 = undefined;
            const comment = std.fmt.bufPrint(&comment_buf, "✓ Commit merged in pull request #{d}", .{top_pr.number}) catch continue;

            gh_client.commentPR(info.number, comment) catch {};
            gh_client.closePR(info.number) catch {};
            gh_client.deleteBranch(info.branch_name) catch {};

            ui.print("    Closed #{d} {s}\n", .{ info.number, info.title });
        }
    }

    ui.print("\n", .{});
    ui.print("  {s}{s} Merged {d} commit{s} via #{d}{s}\n", .{
        ui.Style.green,
        ui.Style.check,
        mergeable_count,
        if (mergeable_count == 1) "" else "s",
        top_pr.number,
        ui.Style.reset,
    });

    ui.print("  Fetching {s}...", .{cfg.remote});
    const fetch_output = git.run(allocator, &.{ "fetch", cfg.remote });
    if (fetch_output) |output| {
        allocator.free(output);
        ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });
    } else |_| {
        ui.print(" {s}failed{s}\n", .{ ui.Style.yellow, ui.Style.reset });
    }

    if (auto_rebase) {
        var rebase_target_buf: [256]u8 = undefined;
        const rebase_target = std.fmt.bufPrint(&rebase_target_buf, "{s}/{s}", .{ cfg.remote, cfg.main_branch }) catch {
            ui.printError("Failed to format rebase target\n", .{});
            return;
        };

        ui.print("  Rebasing onto {s}...", .{rebase_target});
        const rebase_output = git.run(allocator, &.{ "rebase", rebase_target });
        if (rebase_output) |output| {
            allocator.free(output);
            ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });
        } else |_| {
            ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
            ui.printError("Rebase failed. Resolve conflicts and run 'git rebase --continue'\n", .{});
        }
    }

    ui.print("\n", .{});
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
        \\    merge, m          Merge all mergeable PRs (top PR targets main, lower PRs closed)
        \\    help, --help, -h  Show this help message
        \\
        \\MERGE OPTIONS:
        \\    -ar, --auto-rebase  Rebase current branch onto updated main after merge
        \\
        \\EXAMPLES:
        \\    ztk init          # Initialize ztk config
        \\    ztk status        # Show stack status
        \\    ztk update        # Sync stack to GitHub
        \\    ztk merge         # Merge ready PRs
        \\
    ;
    ui.print("{s}", .{usage});
}
