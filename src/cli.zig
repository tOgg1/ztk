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
    sync,
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
            .{ "sync", .sync },
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
            .sync => cmdSync(allocator),
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

fn injectZtkIds(allocator: std.mem.Allocator, stk: stack.Stack, cfg: config.Config) bool {
    var needs_injection = false;
    for (stk.commits) |commit| {
        if (commit.ztk_id == null and !commit.is_wip) {
            needs_injection = true;
            break;
        }
    }

    if (!needs_injection) return true;

    ui.print("  Adding ztk-id markers to commits...\n", .{});

    const did_stash = git.stash(allocator) catch false;

    var base_buf: [256]u8 = undefined;
    const remote_base = std.fmt.bufPrint(&base_buf, "{s}/{s}", .{ cfg.remote, cfg.main_branch }) catch {
        ui.printError("Buffer overflow\n", .{});
        return false;
    };

    const merge_base = git.getMergeBase(allocator, remote_base, "HEAD") catch |err| {
        if (err == git.GitError.CommandFailed) {
            const mb2 = git.getMergeBase(allocator, cfg.main_branch, "HEAD") catch {
                ui.printError("Failed to find merge base\n", .{});
                return false;
            };
            defer allocator.free(mb2);
            return injectZtkIdsRebase(allocator, mb2, stk, did_stash);
        }
        ui.printError("Failed to find merge base\n", .{});
        return false;
    };
    defer allocator.free(merge_base);

    return injectZtkIdsRebase(allocator, merge_base, stk, did_stash);
}

fn injectZtkIdsRebase(allocator: std.mem.Allocator, merge_base: []const u8, stk: stack.Stack, did_stash: bool) bool {
    var current_base = allocator.dupe(u8, merge_base) catch return false;
    defer allocator.free(current_base);

    for (stk.commits) |commit| {
        if (commit.is_wip) continue;

        var parent_ref_buf: [64]u8 = undefined;
        const parent_ref = std.fmt.bufPrint(&parent_ref_buf, "{s}^", .{commit.sha}) catch {
            restoreAfterRebase(allocator, stk.head_branch, did_stash);
            return false;
        };

        _ = git.run(allocator, &.{ "checkout", commit.sha }) catch {
            ui.printError("Failed to checkout {s}\n", .{commit.short_sha});
            restoreAfterRebase(allocator, stk.head_branch, did_stash);
            return false;
        };

        _ = git.run(allocator, &.{ "rebase", "--onto", current_base, parent_ref, commit.sha }) catch {};

        if (commit.ztk_id == null) {
            const msg = git.getCommitMessage(allocator, "HEAD") catch {
                ui.printError("Failed to get commit message\n", .{});
                restoreAfterRebase(allocator, stk.head_branch, did_stash);
                return false;
            };
            defer allocator.free(msg);

            const new_id = git.generateZtkId(allocator) catch {
                ui.printError("Failed to generate ztk-id\n", .{});
                restoreAfterRebase(allocator, stk.head_branch, did_stash);
                return false;
            };
            defer allocator.free(new_id);

            const trimmed_msg = std.mem.trim(u8, msg, "\n\r ");
            var new_msg_buf: [8192]u8 = undefined;
            const new_msg = std.fmt.bufPrint(&new_msg_buf, "{s}\n\nztk-id: {s}", .{ trimmed_msg, new_id }) catch {
                ui.printError("Message too long\n", .{});
                restoreAfterRebase(allocator, stk.head_branch, did_stash);
                return false;
            };

            git.amendCommitMessage(allocator, new_msg) catch {
                ui.printError("Failed to amend commit\n", .{});
                restoreAfterRebase(allocator, stk.head_branch, did_stash);
                return false;
            };

            ui.print("    └─ Added ztk-id to: {s}{s}{s}\n", .{ ui.Style.dim, commit.title, ui.Style.reset });
        }

        const new_sha = git.run(allocator, &.{ "rev-parse", "HEAD" }) catch {
            restoreAfterRebase(allocator, stk.head_branch, did_stash);
            return false;
        };
        allocator.free(current_base);
        current_base = allocator.dupe(u8, std.mem.trim(u8, new_sha, "\n\r ")) catch {
            allocator.free(new_sha);
            return false;
        };
        allocator.free(new_sha);
    }

    _ = git.run(allocator, &.{ "checkout", stk.head_branch }) catch {
        ui.printError("Failed to return to branch\n", .{});
        return false;
    };

    _ = git.run(allocator, &.{ "reset", "--hard", current_base }) catch {
        ui.printError("Failed to update branch\n", .{});
        return false;
    };

    if (did_stash) {
        git.stashPop(allocator) catch {};
    }

    ui.print("  {s}{s}{s} ztk-ids added\n\n", .{ ui.Style.green, ui.Style.check, ui.Style.reset });
    return true;
}

fn restoreAfterRebase(allocator: std.mem.Allocator, branch: []const u8, did_stash: bool) void {
    _ = git.run(allocator, &.{ "checkout", branch }) catch null;
    if (did_stash) {
        git.stashPop(allocator) catch {};
    }
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

    ui.print("\n", .{});

    if (!injectZtkIds(allocator, stk, cfg)) {
        ui.printError("Failed to inject ztk-ids. Aborting update.\n", .{});
        return;
    }

    const updated_stk = stack.readStack(allocator, cfg) catch |err| {
        ui.printError("Failed to re-read stack: {any}\n", .{err});
        return;
    };
    defer {
        var s = updated_stk;
        s.deinit(allocator);
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

    const specs = stack.derivePRSpecs(allocator, updated_stk, cfg) catch {
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

    ui.print("  Syncing stack to GitHub...\n\n", .{});

    var created: usize = 0;
    var updated: usize = 0;
    var skipped: usize = 0;

    for (specs) |spec| {
        const commit = updated_stk.commits[created + updated + skipped];
        const is_current = (created + updated + skipped) == updated_stk.commits.len - 1;
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

fn cmdSync(allocator: std.mem.Allocator) void {
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

    ui.print("\n  Syncing with {s}/{s}...\n\n", .{ cfg.remote, cfg.main_branch });

    ui.print("  {s}Fetching...{s}", .{ ui.Style.dim, ui.Style.reset });
    git.fetch(allocator, cfg.remote) catch {
        ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
        ui.printError("Failed to fetch from {s}\n", .{cfg.remote});
        return;
    };
    ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });

    var rebase_target_buf: [256]u8 = undefined;
    const rebase_target = std.fmt.bufPrint(&rebase_target_buf, "{s}/{s}", .{ cfg.remote, cfg.main_branch }) catch {
        ui.printError("Buffer overflow\n", .{});
        return;
    };

    ui.print("  {s}Rebasing onto {s}...{s}", .{ ui.Style.dim, rebase_target, ui.Style.reset });
    git.rebaseOnto(allocator, rebase_target) catch {
        ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
        ui.printError("Rebase failed. Resolve conflicts manually, then run 'git rebase --continue'\n", .{});
        return;
    };
    ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });

    const current_branch = git.currentBranch(allocator) catch {
        ui.printError("Failed to get current branch\n", .{});
        return;
    };
    defer allocator.free(current_branch);

    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "ztk/{s}/*", .{current_branch}) catch {
        ui.printError("Buffer overflow\n", .{});
        return;
    };

    const ztk_branches = git.listBranches(allocator, pattern) catch {
        ui.print("  {s}No ztk branches to clean{s}\n", .{ ui.Style.dim, ui.Style.reset });
        ui.print("\n  {s}{s}{s} Sync complete\n\n", .{ ui.Style.green, ui.Style.check, ui.Style.reset });
        return;
    };
    defer {
        for (ztk_branches) |b| allocator.free(b);
        allocator.free(ztk_branches);
    }

    if (ztk_branches.len == 0) {
        ui.print("\n  {s}{s}{s} Sync complete\n\n", .{ ui.Style.green, ui.Style.check, ui.Style.reset });
        return;
    }

    var gh_client: ?github.Client = github.Client.init(allocator, cfg) catch |err| blk: {
        if (err == github.GitHubError.NoToken) {
            ui.print("  {s}(No GitHub token - skipping branch cleanup){s}\n", .{ ui.Style.dim, ui.Style.reset });
        }
        break :blk null;
    };
    defer if (gh_client) |*c| c.deinit();

    var cleaned_local: usize = 0;
    var cleaned_remote: usize = 0;

    ui.print("\n  {s}Cleaning merged branches...{s}\n", .{ ui.Style.dim, ui.Style.reset });

    for (ztk_branches) |branch| {
        const is_merged = if (gh_client) |*client| client.isPRMerged(branch) else false;

        if (is_merged) {
            git.deleteBranch(allocator, branch, true) catch continue;
            ui.print("    └─ Deleted local: {s}{s}{s}\n", .{ ui.Style.dim, branch, ui.Style.reset });
            cleaned_local += 1;

            git.deleteRemoteBranch(allocator, cfg.remote, branch) catch continue;
            ui.print("    └─ Deleted remote: {s}{s}/{s}{s}\n", .{ ui.Style.dim, cfg.remote, branch, ui.Style.reset });
            cleaned_remote += 1;
        }
    }

    ui.print("\n  {s}{s}{s} Sync complete", .{ ui.Style.green, ui.Style.check, ui.Style.reset });
    if (cleaned_local > 0) {
        ui.print(" ({d} branch{s} cleaned)", .{ cleaned_local, if (cleaned_local == 1) "" else "es" });
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
        \\    sync              Fetch, rebase on main, and clean merged branches
        \\    help, --help, -h  Show this help message
        \\
        \\EXAMPLES:
        \\    ztk init          # Initialize ztk config
        \\    ztk status        # Show stack status
        \\    ztk update        # Sync stack to GitHub
        \\    ztk sync          # Rebase on main and clean up
        \\
    ;
    ui.print("{s}", .{usage});
}
