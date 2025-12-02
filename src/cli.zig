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

const PRInfo = struct {
    pr: ?github.PullRequest,
    status: ?github.PRStatus,
};

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

    var gh_client: ?github.Client = github.Client.init(allocator, cfg) catch |err| blk: {
        if (err == github.GitHubError.NoToken) {
            ui.print("{s}(No GitHub token - PR status unavailable){s}\n", .{ ui.Style.dim, ui.Style.reset });
        }
        break :blk null;
    };
    defer if (gh_client) |*c| c.deinit();

    const specs = stack.derivePRSpecs(allocator, stk, cfg) catch {
        ui.printError("Failed to derive PR specs\n", .{});
        return;
    };
    defer {
        for (specs) |spec| {
            allocator.free(spec.branch_name);
            allocator.free(spec.base_ref);
        }
        allocator.free(specs);
    }

    var pr_infos = allocator.alloc(PRInfo, stk.commits.len) catch {
        ui.printError("Out of memory\n", .{});
        return;
    };
    defer {
        for (pr_infos) |*info| {
            if (info.pr) |*pr| pr.deinit(allocator);
        }
        allocator.free(pr_infos);
    }

    for (specs, 0..) |spec, idx| {
        if (gh_client) |*client| {
            if (client.findPR(spec.branch_name) catch null) |pr| {
                const status = client.getPRStatus(pr);
                pr_infos[idx] = .{ .pr = pr, .status = status };
            } else {
                pr_infos[idx] = .{ .pr = null, .status = null };
            }
        } else {
            pr_infos[idx] = .{ .pr = null, .status = null };
        }
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
        const pr_info = pr_infos[i];
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

        if (pr_info.pr) |pr| {
            ui.print("  {s}{s}{s}  {s}#{d}{s}", .{
                ui.Style.dim,
                ui.Style.pipe,
                ui.Style.reset,
                ui.Style.blue,
                pr.number,
                ui.Style.reset,
            });

            if (pr_info.status) |status| {
                ui.print(" · {s}{s}{s} Checks", .{
                    status.checks.color(),
                    status.checks.icon(),
                    ui.Style.reset,
                });
                ui.print(" · {s}{s}{s} {s}", .{
                    status.review.color(),
                    status.review.icon(),
                    ui.Style.reset,
                    status.review.label(),
                });
                if (status.mergeable != .unknown) {
                    if (status.mergeable == .conflicting) {
                        ui.print(" · {s}{s} Conflicts{s}", .{
                            status.mergeable.color(),
                            status.mergeable.icon(),
                            ui.Style.reset,
                        });
                    }
                }
            }
            ui.print("\n", .{});
        } else {
            ui.print("  {s}{s}{s}  {s}No PR{s}\n", .{
                ui.Style.dim,
                ui.Style.pipe,
                ui.Style.reset,
                ui.Style.dim,
                ui.Style.reset,
            });
        }
        ui.print("  {s}{s}{s}\n", .{ ui.Style.dim, ui.Style.pipe, ui.Style.reset });
    }

    ui.print("  {s}{s}{s} {s}{s}{s}\n", .{ ui.Style.dim, ui.Style.other, ui.Style.reset, ui.Style.dim, stk.base_branch, ui.Style.reset });
    ui.print("\n", .{});

    var wip_count: usize = 0;
    var pr_count: usize = 0;
    var ready_count: usize = 0;
    for (stk.commits, 0..) |c, idx| {
        if (c.is_wip) wip_count += 1;
        if (pr_infos[idx].pr != null) {
            pr_count += 1;
            if (pr_infos[idx].status) |status| {
                if (status.checks == .success and status.review == .approved and status.mergeable != .conflicting) {
                    ready_count += 1;
                }
            }
        }
    }

    ui.print("  Summary: {d} commit{s}", .{ stk.commits.len, if (stk.commits.len == 1) "" else "s" });
    if (pr_count > 0) {
        ui.print(" · {s}{d} PR{s}{s}", .{
            ui.Style.blue,
            pr_count,
            if (pr_count == 1) "" else "s",
            ui.Style.reset,
        });
    }
    if (ready_count > 0) {
        ui.print(" · {s}{d} ready to merge{s}", .{ ui.Style.green, ready_count, ui.Style.reset });
    }
    if (wip_count > 0) {
        ui.print(" · {s}{d} WIP{s}", .{ ui.Style.yellow, wip_count, ui.Style.reset });
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
        ui.print("No commits to sync\n", .{});
        return;
    }

    var gh_client = github.Client.init(allocator, cfg) catch |err| {
        if (err == github.GitHubError.NoToken) {
            ui.printError("No GitHub token. Set GITHUB_TOKEN or install gh CLI.\n", .{});
        } else {
            ui.printError("Failed to init GitHub client: {any}\n", .{err});
        }
        return;
    };
    defer gh_client.deinit();

    const specs = stack.derivePRSpecs(allocator, stk, cfg) catch {
        ui.printError("Failed to derive PR specs\n", .{});
        return;
    };
    defer {
        for (specs) |spec| {
            allocator.free(spec.branch_name);
            allocator.free(spec.base_ref);
        }
        allocator.free(specs);
    }

    ui.print("\n  Syncing stack to GitHub...\n\n", .{});

    var created: usize = 0;
    var updated: usize = 0;
    var skipped: usize = 0;

    for (specs) |spec| {
        const commit = stk.commits[created + updated + skipped];
        const is_current = (created + updated + skipped) == stk.commits.len - 1;
        const icon = if (is_current) ui.Style.current else ui.Style.other;
        const icon_color = if (is_current) ui.Style.green else ui.Style.blue;

        if (spec.is_wip) {
            ui.print("  {s}{s}{s} {s}  {s}[WIP skipped]{s}\n", .{
                ui.Style.yellow,
                icon,
                ui.Style.reset,
                commit.title,
                ui.Style.yellow,
                ui.Style.reset,
            });
            skipped += 1;
            continue;
        }

        ui.print("  {s}{s}{s} {s}\n", .{ icon_color, icon, ui.Style.reset, commit.title });

        git.ensureBranchAt(allocator, spec.branch_name, spec.sha) catch |err| {
            ui.print("    └─ {s}Failed to create branch: {any}{s}\n", .{ ui.Style.red, err, ui.Style.reset });
            continue;
        };
        ui.print("    └─ Branch: {s}{s}{s}\n", .{ ui.Style.dim, spec.branch_name, ui.Style.reset });

        git.push(allocator, cfg.remote, spec.branch_name, true) catch |err| {
            ui.print("    └─ {s}Failed to push: {any}{s}\n", .{ ui.Style.red, err, ui.Style.reset });
            continue;
        };
        ui.print("    └─ Pushed\n", .{});

        const existing_pr = gh_client.findPR(spec.branch_name) catch null;
        if (existing_pr) |pr| {
            var mutable_pr = pr;
            defer mutable_pr.deinit(allocator);
            gh_client.updatePR(pr.number, spec.title, spec.body, spec.base_ref) catch |err| {
                ui.print("    └─ {s}Failed to update PR: {any}{s}\n", .{ ui.Style.red, err, ui.Style.reset });
                continue;
            };
            ui.print("    └─ PR {s}#{d}{s} updated\n", .{ ui.Style.blue, pr.number, ui.Style.reset });
            updated += 1;
        } else {
            const new_pr = gh_client.createPR(spec.branch_name, spec.base_ref, spec.title, spec.body) catch |err| {
                ui.print("    └─ {s}Failed to create PR: {any}{s}\n", .{ ui.Style.red, err, ui.Style.reset });
                continue;
            };
            var mutable_pr = new_pr;
            defer mutable_pr.deinit(allocator);
            ui.print("    └─ PR {s}#{d}{s} created\n", .{ ui.Style.blue, new_pr.number, ui.Style.reset });
            created += 1;
        }
        ui.print("\n", .{});
    }

    ui.print("  {s}{s}{s} Stack synced: {d} PR{s}", .{
        ui.Style.green,
        ui.Style.check,
        ui.Style.reset,
        created + updated,
        if (created + updated == 1) "" else "s",
    });
    if (created > 0) {
        ui.print(" ({d} created", .{created});
        if (updated > 0) ui.print(", {d} updated", .{updated});
        ui.print(")", .{});
    } else if (updated > 0) {
        ui.print(" ({d} updated)", .{updated});
    }
    if (skipped > 0) {
        ui.print(", {s}{d} WIP skipped{s}", .{ ui.Style.yellow, skipped, ui.Style.reset });
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
