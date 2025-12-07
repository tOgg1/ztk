const std = @import("std");
const ui = @import("ui.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const stack = @import("stack.zig");
const github = @import("github.zig");
const review = @import("review.zig");
const tui = @import("tui.zig");
const clipboard = @import("clipboard.zig");
const prompt = @import("prompt.zig");

pub const Command = enum {
    init,
    status,
    update,
    sync,
    modify,
    absorb,
    merge,
    review_cmd,
    open,
    help,

    pub fn fromString(str: []const u8) ?Command {
        const commands = std.StaticStringMap(Command).initComptime(.{
            .{ "init", .init },
            .{ "status", .status },
            .{ "s", .status },
            .{ "st", .status },
            .{ "update", .update },
            .{ "push", .update },
            .{ "u", .update },
            .{ "up", .update },
            .{ "sync", .sync },
            .{ "modify", .modify },
            .{ "absorb", .absorb },
            .{ "a", .absorb },
            .{ "ab", .absorb },
            .{ "merge", .merge },
            .{ "m", .merge },
            .{ "review", .review_cmd },
            .{ "r", .review_cmd },
            .{ "rv", .review_cmd },
            .{ "feedback", .review_cmd },
            .{ "open", .open },
            .{ "o", .open },
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
            .modify => cmdModify(allocator, args),
            .absorb => cmdAbsorb(allocator, args),
            .merge => cmdMerge(allocator, args),
            .review_cmd => cmdReview(allocator, args),
            .open => cmdOpen(allocator),
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
        for (specs) |*spec| {
            var s = spec.*;
            s.deinit(allocator);
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

        if (git.run(allocator, &.{ "checkout", commit.sha })) |out| {
            allocator.free(out);
        } else |_| {
            ui.printError("Failed to checkout {s}\n", .{commit.short_sha});
            restoreAfterRebase(allocator, stk.head_branch, did_stash);
            return false;
        }

        if (git.run(allocator, &.{ "rebase", "--onto", current_base, parent_ref, commit.sha })) |out| {
            allocator.free(out);
        } else |_| {}

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

    if (git.run(allocator, &.{ "checkout", stk.head_branch })) |out| {
        allocator.free(out);
    } else |_| {
        ui.printError("Failed to return to branch\n", .{});
        return false;
    }

    if (git.run(allocator, &.{ "reset", "--hard", current_base })) |out| {
        allocator.free(out);
    } else |_| {
        ui.printError("Failed to update branch\n", .{});
        return false;
    }

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
        for (specs) |*spec| {
            var s = spec.*;
            s.deinit(allocator);
        }
        allocator.free(specs);
    }

    ui.print("  Syncing stack to GitHub...\n\n", .{});

    var created: usize = 0;
    var updated: usize = 0;
    var unchanged: usize = 0;
    var skipped: usize = 0;

    for (specs) |spec| {
        const commit = updated_stk.commits[created + updated + unchanged + skipped];
        const is_current = (created + updated + unchanged + skipped) == updated_stk.commits.len - 1;
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

        const pushed = git.push(allocator, cfg.remote, spec.branch_name, true) catch |err| {
            ui.print("    └─ {s}Failed to push: {any}{s}\n", .{ ui.Style.red, err, ui.Style.reset });
            continue;
        };
        if (pushed) {
            ui.print("    └─ Pushed\n", .{});
        }

        const existing_pr = gh_client.findPR(spec.branch_name) catch null;
        if (existing_pr) |pr| {
            var mutable_pr = pr;
            defer mutable_pr.deinit(allocator);

            // Check if anything actually changed
            const title_changed = !std.mem.eql(u8, pr.title, spec.title);
            const body_changed = !std.mem.eql(u8, pr.body, spec.body);
            const base_changed = !std.mem.eql(u8, pr.base_ref, spec.base_ref);

            if (title_changed or body_changed or base_changed) {
                gh_client.updatePR(pr.number, spec.title, spec.body, spec.base_ref) catch |err| {
                    ui.print("    └─ {s}Failed to update PR: {any}{s}\n", .{ ui.Style.red, err, ui.Style.reset });
                    continue;
                };
                ui.print("    └─ PR {s}#{d}{s} updated\n", .{ ui.Style.blue, pr.number, ui.Style.reset });
                updated += 1;
            } else {
                ui.print("    └─ PR {s}#{d}{s} unchanged\n", .{ ui.Style.dim, pr.number, ui.Style.reset });
                unchanged += 1;
            }
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
        created + updated + unchanged,
        if (created + updated + unchanged == 1) "" else "s",
    });
    if (created > 0 or updated > 0 or unchanged > 0) {
        ui.print(" (", .{});
        var first = true;
        if (created > 0) {
            ui.print("{d} created", .{created});
            first = false;
        }
        if (updated > 0) {
            if (!first) ui.print(", ", .{});
            ui.print("{d} updated", .{updated});
            first = false;
        }
        if (unchanged > 0) {
            if (!first) ui.print(", ", .{});
            ui.print("{d} unchanged", .{unchanged});
        }
        ui.print(")", .{});
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

fn cmdModify(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    var auto_update = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update")) {
            auto_update = true;
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
        ui.printError("No commits to modify\n", .{});
        return;
    }

    if (!git.hasStagedChanges(allocator)) {
        ui.printError("No staged changes. Stage your changes first with 'git add'.\n", .{});
        return;
    }

    // If there's only one commit, skip the selection prompt
    if (stk.commits.len == 1) {
        const target_commit = stk.commits[0];
        ui.print("\n  Modifying: {s}{s}{s}\n", .{ ui.Style.bold, target_commit.title, ui.Style.reset });

        git.commitFixup(allocator, target_commit.sha) catch {
            ui.printError("Failed to create fixup commit\n", .{});
            return;
        };

        var base_buf: [256]u8 = undefined;
        const rebase_base = std.fmt.bufPrint(&base_buf, "{s}/{s}", .{ cfg.remote, cfg.main_branch }) catch {
            ui.printError("Buffer overflow\n", .{});
            return;
        };

        git.rebaseInteractiveAutosquash(allocator, rebase_base) catch {
            ui.printError("Rebase failed. Resolve conflicts, then run 'git rebase --continue'.\n", .{});
            return;
        };

        ui.print("  {s}{s}{s} Commit modified and stack rebased\n\n", .{ ui.Style.green, ui.Style.check, ui.Style.reset });

        if (auto_update) {
            cmdUpdate(allocator);
        } else {
            ui.print("  Run {s}ztk update{s} to sync changes to GitHub.\n\n", .{ ui.Style.bold, ui.Style.reset });
        }
        return;
    }

    ui.print("\n  Select a commit to modify:\n\n", .{});

    var i: usize = stk.commits.len;
    while (i > 0) {
        i -= 1;
        const commit = stk.commits[i];
        const num = stk.commits.len - i;
        const is_current = i == stk.commits.len - 1;

        if (is_current) {
            ui.print("    {s}[{d}]{s} {s}{s}{s} {s}{s}{s}\n", .{
                ui.Style.bold,
                num,
                ui.Style.reset,
                ui.Style.green,
                ui.Style.current,
                ui.Style.reset,
                ui.Style.bold,
                commit.title,
                ui.Style.reset,
            });
        } else {
            ui.print("    {s}[{d}]{s} {s}{s}{s} {s}\n", .{
                ui.Style.dim,
                num,
                ui.Style.reset,
                ui.Style.blue,
                ui.Style.other,
                ui.Style.reset,
                commit.title,
            });
        }
    }

    ui.print("\n", .{});

    if (stk.commits.len == 1) {
        ui.print("  Commit to modify (1): ", .{});
    } else {
        ui.print("  Commit to modify (1-{d}): ", .{stk.commits.len});
    }

    var input_buf: [32]u8 = undefined;
    var input_len: usize = 0;
    const stdin_fd = std.posix.STDIN_FILENO;
    while (input_len < input_buf.len) {
        const bytes_read = std.posix.read(stdin_fd, input_buf[input_len..]) catch {
            ui.printError("Failed to read input\n", .{});
            return;
        };
        if (bytes_read == 0) break;
        input_len += bytes_read;
        if (std.mem.indexOfScalar(u8, input_buf[0..input_len], '\n')) |_| break;
    }
    const input: ?[]const u8 = if (input_len > 0) input_buf[0..input_len] else null;

    if (input == null) {
        ui.print("\n  Cancelled.\n\n", .{});
        return;
    }

    const trimmed = std.mem.trim(u8, input.?, " \r\t\n");
    if (trimmed.len == 0) {
        ui.print("  Cancelled.\n\n", .{});
        return;
    }

    const commit_num = std.fmt.parseInt(usize, trimmed, 10) catch {
        ui.printError("Invalid input. Enter a number.\n", .{});
        return;
    };

    if (commit_num < 1 or commit_num > stk.commits.len) {
        ui.printError("Invalid commit number: {d}. Must be between 1 and {d}.\n", .{ commit_num, stk.commits.len });
        return;
    }

    const commit_idx = stk.commits.len - commit_num;
    const target_commit = stk.commits[commit_idx];

    ui.print("\n  Modifying: {s}{s}{s}\n", .{ ui.Style.bold, target_commit.title, ui.Style.reset });

    git.commitFixup(allocator, target_commit.sha) catch {
        ui.printError("Failed to create fixup commit\n", .{});
        return;
    };

    var base_buf: [256]u8 = undefined;
    const rebase_base = std.fmt.bufPrint(&base_buf, "{s}/{s}", .{ cfg.remote, cfg.main_branch }) catch {
        ui.printError("Buffer overflow\n", .{});
        return;
    };

    git.rebaseInteractiveAutosquash(allocator, rebase_base) catch {
        ui.printError("Rebase failed. Resolve conflicts, then run 'git rebase --continue'.\n", .{});
        return;
    };

    ui.print("  {s}{s}{s} Commit modified and stack rebased\n\n", .{ ui.Style.green, ui.Style.check, ui.Style.reset });

    if (auto_update) {
        cmdUpdate(allocator);
    } else {
        ui.print("  Run {s}ztk update{s} to sync changes to GitHub.\n\n", .{ ui.Style.bold, ui.Style.reset });
    }
}

const AbsorbTarget = struct {
    commit_sha: []const u8,
    commit_title: []const u8,
    hunk_count: usize,
    files: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *AbsorbTarget, allocator: std.mem.Allocator) void {
        for (self.files.items) |f| allocator.free(f);
        self.files.deinit(allocator);
    }
};

fn cmdAbsorb(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    var auto_update = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update")) {
            auto_update = true;
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
        ui.printError("No commits in stack to absorb into\n", .{});
        return;
    }

    if (!git.hasStagedChanges(allocator)) {
        ui.printError("No staged changes. Stage your changes first with 'git add'.\n", .{});
        return;
    }

    const diff_output = git.getStagedDiff(allocator) catch {
        ui.printError("Failed to get staged diff\n", .{});
        return;
    };
    defer allocator.free(diff_output);

    if (diff_output.len == 0) {
        ui.printError("No staged changes found\n", .{});
        return;
    }

    const hunks = git.parseDiffHunks(allocator, diff_output) catch {
        ui.printError("Failed to parse diff hunks\n", .{});
        return;
    };
    defer {
        for (hunks) |*h| {
            var hunk = h.*;
            hunk.deinit(allocator);
        }
        allocator.free(hunks);
    }

    if (hunks.len == 0) {
        ui.printError("No hunks found in staged changes\n", .{});
        return;
    }

    var commit_sha_set = std.StringHashMap(void).init(allocator);
    defer commit_sha_set.deinit();
    for (stk.commits) |commit| {
        commit_sha_set.put(commit.sha, {}) catch {};
    }

    var absorb_map = std.StringHashMap(AbsorbTarget).init(allocator);
    defer {
        var iter = absorb_map.iterator();
        while (iter.next()) |entry| {
            var target = entry.value_ptr;
            target.deinit(allocator);
        }
        absorb_map.deinit();
    }

    var unabsorbable_count: usize = 0;

    for (hunks) |hunk| {
        if (hunk.old_count == 0) {
            unabsorbable_count += 1;
            continue;
        }

        const blame_results = git.blameLines(allocator, hunk.file_path, hunk.old_start, hunk.old_count) catch {
            unabsorbable_count += 1;
            continue;
        };
        defer {
            for (blame_results) |*r| {
                var result = r.*;
                result.deinit(allocator);
            }
            allocator.free(blame_results);
        }

        if (blame_results.len == 0) {
            unabsorbable_count += 1;
            continue;
        }

        var target_sha: ?[]const u8 = null;
        var all_same = true;

        for (blame_results) |result| {
            if (!commit_sha_set.contains(result.sha)) {
                all_same = false;
                break;
            }
            if (target_sha == null) {
                target_sha = result.sha;
            } else if (!std.mem.eql(u8, target_sha.?, result.sha)) {
                all_same = false;
                break;
            }
        }

        if (!all_same or target_sha == null) {
            unabsorbable_count += 1;
            continue;
        }

        const sha = target_sha.?;

        if (absorb_map.getPtr(sha)) |target| {
            target.hunk_count += 1;
            var found = false;
            for (target.files.items) |f| {
                if (std.mem.eql(u8, f, hunk.file_path)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const file_copy = allocator.dupe(u8, hunk.file_path) catch continue;
                target.files.append(allocator, file_copy) catch {
                    allocator.free(file_copy);
                    continue;
                };
            }
        } else {
            var commit_title: []const u8 = "unknown";
            for (stk.commits) |commit| {
                if (std.mem.eql(u8, commit.sha, sha)) {
                    commit_title = commit.title;
                    break;
                }
            }

            var files = std.ArrayListUnmanaged([]const u8){};
            const file_copy = allocator.dupe(u8, hunk.file_path) catch continue;
            files.append(allocator, file_copy) catch {
                allocator.free(file_copy);
                continue;
            };

            absorb_map.put(sha, .{
                .commit_sha = sha,
                .commit_title = commit_title,
                .hunk_count = 1,
                .files = files,
            }) catch continue;
        }
    }

    if (absorb_map.count() == 0) {
        ui.print("\n  {s}No hunks can be absorbed deterministically.{s}\n", .{ ui.Style.yellow, ui.Style.reset });
        ui.print("  Use {s}ztk modify{s} to manually select a commit.\n\n", .{ ui.Style.bold, ui.Style.reset });
        return;
    }

    ui.print("\n  {s}Absorb plan:{s}\n\n", .{ ui.Style.bold, ui.Style.reset });

    var absorb_iter = absorb_map.iterator();
    var total_hunks: usize = 0;
    while (absorb_iter.next()) |entry| {
        const target = entry.value_ptr;
        total_hunks += target.hunk_count;

        ui.print("  {s}{s}{s} {s}\n", .{
            ui.Style.blue,
            ui.Style.other,
            ui.Style.reset,
            target.commit_title,
        });
        ui.print("  {s}{s}{s}  {d} hunk{s} from: ", .{
            ui.Style.dim,
            ui.Style.pipe,
            ui.Style.reset,
            target.hunk_count,
            if (target.hunk_count == 1) "" else "s",
        });
        for (target.files.items, 0..) |file, i| {
            if (i > 0) ui.print(", ", .{});
            ui.print("{s}{s}{s}", .{ ui.Style.dim, file, ui.Style.reset });
        }
        ui.print("\n\n", .{});
    }

    if (unabsorbable_count > 0) {
        ui.print("  {s}{s} {d} hunk{s} cannot be absorbed (new lines or mixed origins){s}\n\n", .{
            ui.Style.yellow,
            ui.Style.warning,
            unabsorbable_count,
            if (unabsorbable_count == 1) "" else "s",
            ui.Style.reset,
        });
    }

    ui.print("  Absorb {d} hunk{s} into {d} commit{s}? [y/N]: ", .{
        total_hunks,
        if (total_hunks == 1) "" else "s",
        absorb_map.count(),
        if (absorb_map.count() == 1) "" else "s",
    });

    var input_buf: [32]u8 = undefined;
    var input_len: usize = 0;
    const stdin_fd = std.posix.STDIN_FILENO;
    while (input_len < input_buf.len) {
        const bytes_read = std.posix.read(stdin_fd, input_buf[input_len..]) catch {
            ui.printError("Failed to read input\n", .{});
            return;
        };
        if (bytes_read == 0) break;
        input_len += bytes_read;
        if (std.mem.indexOfScalar(u8, input_buf[0..input_len], '\n')) |_| break;
    }
    const input: ?[]const u8 = if (input_len > 0) input_buf[0..input_len] else null;

    if (input == null) {
        ui.print("\n  Cancelled.\n\n", .{});
        return;
    }

    const trimmed = std.mem.trim(u8, input.?, " \r\t\n");
    if (trimmed.len == 0 or (trimmed[0] != 'y' and trimmed[0] != 'Y')) {
        ui.print("  Cancelled.\n\n", .{});
        return;
    }

    ui.print("\n", .{});

    var commits_to_fixup = std.ArrayListUnmanaged([]const u8){};
    defer commits_to_fixup.deinit(allocator);

    for (stk.commits) |commit| {
        if (absorb_map.contains(commit.sha)) {
            commits_to_fixup.append(allocator, commit.sha) catch continue;
        }
    }

    if (git.run(allocator, &.{"stash"})) |o| {
        allocator.free(o);
    } else |_| {}

    const stash_output = git.run(allocator, &.{ "stash", "list" }) catch null;
    const had_stash = if (stash_output) |o| blk: {
        defer allocator.free(o);
        break :blk o.len > 0;
    } else false;

    for (commits_to_fixup.items) |sha| {
        const target = absorb_map.get(sha) orelse continue;

        if (git.run(allocator, &.{ "stash", "pop" })) |o| allocator.free(o) else |_| {}

        for (target.files.items) |file| {
            if (git.run(allocator, &.{ "add", file })) |o| allocator.free(o) else |_| {}
        }

        git.commitFixup(allocator, sha) catch {
            ui.printError("Failed to create fixup commit for {s}\n", .{target.commit_title});
            continue;
        };

        ui.print("  {s}{s}{s} Created fixup for: {s}\n", .{
            ui.Style.green,
            ui.Style.check,
            ui.Style.reset,
            target.commit_title,
        });

        if (git.run(allocator, &.{"stash"})) |o| allocator.free(o) else |_| {}
    }

    if (had_stash) {
        if (git.run(allocator, &.{ "stash", "pop" })) |o| allocator.free(o) else |_| {}
    }

    var base_buf: [256]u8 = undefined;
    const rebase_base = std.fmt.bufPrint(&base_buf, "{s}/{s}", .{ cfg.remote, cfg.main_branch }) catch {
        ui.printError("Buffer overflow\n", .{});
        return;
    };

    ui.print("\n  {s}Rebasing to squash fixups...{s}", .{ ui.Style.dim, ui.Style.reset });
    git.rebaseInteractiveAutosquash(allocator, rebase_base) catch {
        ui.print(" {s}failed{s}\n", .{ ui.Style.red, ui.Style.reset });
        ui.printError("Rebase failed. Resolve conflicts, then run 'git rebase --continue'.\n", .{});
        return;
    };
    ui.print(" {s}done{s}\n", .{ ui.Style.green, ui.Style.reset });

    ui.print("\n  {s}{s}{s} Absorbed {d} hunk{s} into {d} commit{s}\n\n", .{
        ui.Style.green,
        ui.Style.check,
        ui.Style.reset,
        total_hunks,
        if (total_hunks == 1) "" else "s",
        absorb_map.count(),
        if (absorb_map.count() == 1) "" else "s",
    });

    if (auto_update) {
        cmdUpdate(allocator);
    } else {
        ui.print("  Run {s}ztk update{s} to sync changes to GitHub.\n\n", .{ ui.Style.bold, ui.Style.reset });
    }
}

fn cmdMerge(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    var auto_rebase = false;
    var skip_review = false;
    var force = false;
    var interactive = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rebase")) {
            auto_rebase = true;
        }
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-review")) {
            skip_review = true;
        }
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        }
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
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

    const MergePRInfo = struct {
        number: u32,
        title: []const u8,
        branch_name: []const u8,
        is_mergeable: bool,
    };

    var pr_infos = std.ArrayListUnmanaged(MergePRInfo){};
    defer {
        for (pr_infos.items) |info| {
            allocator.free(info.branch_name);
        }
        pr_infos.deinit(allocator);
    }

    for (stk.commits) |commit| {
        if (commit.is_wip) continue;

        const id_suffix = if (commit.ztk_id) |id|
            id[0..@min(8, id.len)]
        else
            commit.short_sha;

        var branch_buf: [256]u8 = undefined;
        const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
            stk.head_branch,
            id_suffix,
        }) catch continue;

        const pr = gh_client.findPR(branch_name) catch continue;
        if (pr) |found_pr| {
            defer {
                var mutable_pr = found_pr;
                mutable_pr.deinit(allocator);
            }

            if (std.mem.eql(u8, found_pr.state, "closed")) {
                continue;
            }

            const status = gh_client.getPRStatus(found_pr);

            const is_mergeable = if (force)
                status.mergeable != .conflicting
            else
                status.checks == .success and
                    (skip_review or status.review == .approved) and
                    status.mergeable != .conflicting;

            const branch_copy = allocator.dupe(u8, branch_name) catch continue;

            pr_infos.append(allocator, .{
                .number = found_pr.number,
                .title = commit.title,
                .branch_name = branch_copy,
                .is_mergeable = is_mergeable,
            }) catch {
                allocator.free(branch_copy);
                continue;
            };
        }
    }

    if (pr_infos.items.len == 0) {
        ui.print("  No PRs found. Run 'ztk update' first.\n", .{});
        ui.print("\n", .{});
        return;
    }

    var mergeable_count: usize = 0;
    for (pr_infos.items) |info| {
        const status_icon = if (info.is_mergeable) ui.Style.check else ui.Style.cross;
        const status_color = if (info.is_mergeable) ui.Style.green else ui.Style.red;

        ui.print("  {s}{s}{s} #{d} {s}\n", .{
            status_color,
            status_icon,
            ui.Style.reset,
            info.number,
            info.title,
        });

        if (info.is_mergeable) {
            mergeable_count += 1;
        } else {
            break;
        }
    }

    ui.print("\n", .{});

    if (mergeable_count == 0) {
        ui.print("  {s}⚠ No PRs ready to merge{s}\n", .{ ui.Style.yellow, ui.Style.reset });
        ui.print("    PRs need: ✓ CI checks passing, ✓ approved review, ✓ no conflicts\n", .{});
        ui.print("\n", .{});
        return;
    }

    // Interactive mode: let user select up to which PR to merge
    var selected_count = mergeable_count;
    if (interactive and mergeable_count > 1) {
        ui.print("  Select PR to merge up to (1-{d}), or press Enter for all: ", .{mergeable_count});

        var input_buf: [32]u8 = undefined;
        var input_len: usize = 0;
        const stdin_fd = std.posix.STDIN_FILENO;
        while (input_len < input_buf.len) {
            const bytes_read = std.posix.read(stdin_fd, input_buf[input_len..]) catch {
                ui.printError("Failed to read input\n", .{});
                return;
            };
            if (bytes_read == 0) break;
            input_len += bytes_read;
            if (std.mem.indexOfScalar(u8, input_buf[0..input_len], '\n')) |_| break;
        }
        const input: ?[]const u8 = if (input_len > 0) input_buf[0..input_len] else null;

        if (input == null) {
            ui.print("\n  Cancelled.\n\n", .{});
            return;
        }

        const trimmed = std.mem.trim(u8, input.?, " \r\t\n");
        if (trimmed.len > 0) {
            const selection = std.fmt.parseInt(usize, trimmed, 10) catch {
                ui.printError("Invalid input. Enter a number.\n", .{});
                return;
            };

            if (selection < 1 or selection > mergeable_count) {
                ui.printError("Invalid selection: {d}. Must be between 1 and {d}.\n", .{ selection, mergeable_count });
                return;
            }

            selected_count = selection;
        }

        ui.print("\n", .{});
    }

    const top_pr = pr_infos.items[selected_count - 1];

    ui.print("  {s}Merging {d} commit{s} via PR #{d}...{s}\n", .{
        ui.Style.bold,
        selected_count,
        if (selected_count == 1) "" else "s",
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

    if (selected_count > 1) {
        ui.print("\n", .{});
        ui.print("  Closing {d} merged PR{s}...\n", .{ selected_count - 1, if (selected_count == 2) "" else "s" });

        for (pr_infos.items[0 .. selected_count - 1]) |info| {
            var comment_buf: [512]u8 = undefined;
            const comment = std.fmt.bufPrint(&comment_buf, "Commit merged in pull request #{d}", .{top_pr.number}) catch continue;

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
        selected_count,
        if (selected_count == 1) "" else "s",
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

/// Union to hold either a Review or ReviewComment for the TUI
const FeedbackItem = union(enum) {
    comment: review.ReviewComment,
    review_summary: review.Review,
};

/// Global state for review TUI callbacks (needed because Zig doesn't support closures)
const ReviewTUIState = struct {
    var allocator: std.mem.Allocator = undefined;
    var feedback_items: std.ArrayListUnmanaged(FeedbackItem) = .{};
    var pr_summaries: std.ArrayListUnmanaged(review.PRReviewSummary) = .{};
    var secondary_strings: std.ArrayListUnmanaged([]const u8) = .{};
    var tui_items: std.ArrayListUnmanaged(tui.ListItem) = .{};
    var pr_infos: std.ArrayListUnmanaged(tui.PRInfo) = .{};
    var pr_context: ?prompt.PromptContext = null;

    fn init(alloc: std.mem.Allocator) void {
        allocator = alloc;
        feedback_items = .{};
        pr_summaries = .{};
        secondary_strings = .{};
        tui_items = .{};
        pr_infos = .{};
        pr_context = null;
    }

    fn deinit() void {
        for (secondary_strings.items) |s| allocator.free(s);
        secondary_strings.deinit(allocator);

        feedback_items.deinit(allocator);
        tui_items.deinit(allocator);

        for (pr_summaries.items) |*s| s.deinit(allocator);
        pr_summaries.deinit(allocator);

        pr_infos.deinit(allocator);
    }

    fn copyCallback(selected: usize, copy_llm: bool) void {
        if (selected >= feedback_items.items.len) return;

        const item = feedback_items.items[selected];
        if (copy_llm) {
            const context = pr_context orelse prompt.PromptContext{
                .pr_title = "",
                .pr_number = 0,
                .branch = "",
            };

            const formatted = switch (item) {
                .comment => |c| prompt.formatCommentFull(allocator, c, context) catch return,
                .review_summary => |rv| prompt.formatReview(allocator, rv, context) catch return,
            };
            defer allocator.free(formatted);
            clipboard.copy(allocator, formatted) catch {};
        } else {
            const text = switch (item) {
                .comment => |c| c.body,
                .review_summary => |rv| rv.body orelse "",
            };
            clipboard.copy(allocator, text) catch {};
        }
    }

    fn prChangeCallback(alloc: std.mem.Allocator, pr_index: usize) ?[]const tui.ListItem {
        _ = alloc;
        if (pr_index >= pr_summaries.items.len) return null;

        // Clear previous items
        for (secondary_strings.items) |s| allocator.free(s);
        secondary_strings.clearRetainingCapacity();
        feedback_items.clearRetainingCapacity();
        tui_items.clearRetainingCapacity();

        const summary = &pr_summaries.items[pr_index];

        // Update context for copy operations
        pr_context = prompt.PromptContext{
            .pr_title = summary.pr_title,
            .pr_number = summary.pr_number,
            .branch = summary.branch,
        };

        // Build items for this PR
        buildItemsForSummary(summary);

        return tui_items.items;
    }

    fn buildItemsForSummary(summary: *review.PRReviewSummary) void {
        // Add reviews with bodies
        for (summary.reviews) |rv| {
            if (rv.state == .pending) continue;
            if (rv.body == null) continue;

            const item_type: tui.ItemType = switch (rv.state) {
                .approved => .review_approved,
                .changes_requested => .review_changes_requested,
                .commented => .review_commented,
                else => .review_pending,
            };

            tui_items.append(allocator, .{
                .primary = rv.author,
                .secondary = rv.state.toString(),
                .detail = rv.body,
                .context = null,
                .item_type = item_type,
            }) catch continue;

            feedback_items.append(allocator, .{ .review_summary = rv }) catch {
                _ = tui_items.pop();
                continue;
            };
        }

        // Add inline comments
        for (summary.comments) |comment| {
            const secondary: ?[]const u8 = if (comment.path) |path| blk: {
                if (comment.line) |line| {
                    const formatted = std.fmt.allocPrint(allocator, "{s}:{d}", .{ path, line }) catch break :blk path;
                    secondary_strings.append(allocator, formatted) catch {
                        allocator.free(formatted);
                        break :blk path;
                    };
                    break :blk formatted;
                } else {
                    break :blk path;
                }
            } else null;

            tui_items.append(allocator, .{
                .primary = comment.author,
                .secondary = secondary,
                .detail = comment.body,
                .context = null,
                .item_type = .comment,
            }) catch continue;

            feedback_items.append(allocator, .{ .comment = comment }) catch {
                _ = tui_items.pop();
                continue;
            };
        }
    }
};

fn cmdReview(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    // Parse arguments
    var pr_number: ?u32 = null;
    var list_mode = false;
    var stack_mode = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pr") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                pr_number = std.fmt.parseInt(u32, args[i], 10) catch {
                    ui.printError("Invalid PR number: {s}\n", .{args[i]});
                    return;
                };
            } else {
                ui.printError("--pr requires a PR number\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            list_mode = true;
        } else if (std.mem.eql(u8, arg, "--stack") or std.mem.eql(u8, arg, "-s")) {
            stack_mode = true;
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

    var gh_client = github.Client.init(allocator, cfg) catch |err| {
        if (err == github.GitHubError.NoToken) {
            ui.printError("No GitHub token. Set GITHUB_TOKEN or install gh CLI.\n", .{});
        } else {
            ui.printError("Failed to init GitHub client: {any}\n", .{err});
        }
        return;
    };
    defer gh_client.deinit();

    const stk = stack.readStack(allocator, cfg) catch |err| {
        ui.printError("Failed to read stack: {any}\n", .{err});
        return;
    };
    defer {
        var s = stk;
        s.deinit(allocator);
    }

    if (stk.commits.len == 0) {
        ui.printError("No commits in stack. Nothing to review.\n", .{});
        return;
    }

    // Initialize global state
    ReviewTUIState.init(allocator);
    defer ReviewTUIState.deinit();

    if (stack_mode) {
        // Get reviews for all PRs in the stack
        var current_pr_index: usize = 0;

        // Collect all PRs in the stack (bottom to top order in stack, but we iterate for display)
        for (stk.commits, 0..) |commit, idx| {
            if (commit.is_wip) continue;

            const id_suffix = if (commit.ztk_id) |id|
                id[0..@min(8, id.len)]
            else
                commit.short_sha;

            var branch_buf: [256]u8 = undefined;
            const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
                stk.head_branch,
                id_suffix,
            }) catch continue;

            if (gh_client.findPR(branch_name) catch null) |pr| {
                defer {
                    var mutable_pr = pr;
                    mutable_pr.deinit(allocator);
                }

                if (std.mem.eql(u8, pr.state, "closed")) continue;

                // Fetch review summary for this PR
                var summary = gh_client.getPRReviewSummary(pr.number) catch continue;

                ReviewTUIState.pr_summaries.append(allocator, summary) catch {
                    summary.deinit(allocator);
                    continue;
                };

                ReviewTUIState.pr_infos.append(allocator, .{
                    .number = pr.number,
                    .title = commit.title,
                }) catch {
                    // Roll back pr_summaries append to keep lists in sync
                    // We just appended so the list is guaranteed non-empty
                    if (ReviewTUIState.pr_summaries.pop()) |popped| {
                        var item = popped;
                        item.deinit(allocator);
                    }
                    continue;
                };

                // Track which PR is "current" (top of stack)
                if (idx == stk.commits.len - 1) {
                    current_pr_index = ReviewTUIState.pr_summaries.items.len - 1;
                }
            }
        }

        if (ReviewTUIState.pr_summaries.items.len == 0) {
            ui.printError("No PRs found in stack. Run 'ztk update' first.\n", .{});
            return;
        }

        // Build initial items for current PR
        if (current_pr_index < ReviewTUIState.pr_summaries.items.len) {
            const summary = &ReviewTUIState.pr_summaries.items[current_pr_index];
            ReviewTUIState.pr_context = prompt.PromptContext{
                .pr_title = summary.pr_title,
                .pr_number = summary.pr_number,
                .branch = summary.branch,
            };
            ReviewTUIState.buildItemsForSummary(summary);
        }

        if (list_mode) {
            // Print all PRs in list mode
            for (ReviewTUIState.pr_summaries.items) |*summary| {
                printReviewList(allocator, summary);
            }
        } else {
            // Run TUI with PR navigation
            tui.runInteractive(
                allocator,
                ReviewTUIState.tui_items.items,
                ReviewTUIState.copyCallback,
                ReviewTUIState.pr_infos.items,
                &current_pr_index,
                ReviewTUIState.prChangeCallback,
            ) catch |err| {
                ui.printError("TUI error: {any}\n", .{err});
            };
        }
    } else if (pr_number) |num| {
        // Single PR mode with explicit PR number
        var summary = gh_client.getPRReviewSummary(num) catch |err| {
            ui.printError("Failed to get PR review summary: {any}\n", .{err});
            return;
        };
        defer summary.deinit(allocator);

        if (list_mode) {
            printReviewList(allocator, &summary);
        } else {
            runReviewTUISingle(allocator, &summary);
        }
    } else {
        // Default: find PR for current branch (top commit)
        const top_commit = stk.commits[stk.commits.len - 1];
        const id_suffix = if (top_commit.ztk_id) |id|
            id[0..@min(8, id.len)]
        else
            top_commit.short_sha;

        var branch_buf: [256]u8 = undefined;
        const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
            stk.head_branch,
            id_suffix,
        }) catch {
            ui.printError("Buffer overflow\n", .{});
            return;
        };

        const target_pr = if (gh_client.findPR(branch_name) catch null) |pr| blk: {
            defer {
                var mutable_pr = pr;
                mutable_pr.deinit(allocator);
            }
            break :blk pr.number;
        } else {
            ui.printError("No PR found for current branch. Run 'ztk update' first.\n", .{});
            return;
        };

        var summary = gh_client.getPRReviewSummary(target_pr) catch |err| {
            ui.printError("Failed to get PR review summary: {any}\n", .{err});
            return;
        };
        defer summary.deinit(allocator);

        if (list_mode) {
            printReviewList(allocator, &summary);
        } else {
            runReviewTUISingle(allocator, &summary);
        }
    }
}

fn printReviewList(allocator: std.mem.Allocator, summary: *review.PRReviewSummary) void {
    _ = allocator;

    ui.print("\n", .{});
    ui.print("  {s}PR #{d}: {s}{s}\n", .{
        ui.Style.bold,
        summary.pr_number,
        summary.pr_title,
        ui.Style.reset,
    });
    ui.print("  {s}{s}{s}\n\n", .{ ui.Style.dim, summary.pr_url, ui.Style.reset });

    if (summary.reviews.len == 0 and summary.comments.len == 0) {
        ui.print("  {s}No review feedback yet.{s}\n\n", .{ ui.Style.dim, ui.Style.reset });
        return;
    }

    // Print reviews
    for (summary.reviews) |rv| {
        if (rv.state == .pending) continue;
        if (rv.body == null) continue;

        const icon = switch (rv.state) {
            .approved => ui.Style.green ++ ui.Style.check ++ ui.Style.reset,
            .changes_requested => ui.Style.red ++ ui.Style.cross ++ ui.Style.reset,
            .commented => ui.Style.blue ++ "●" ++ ui.Style.reset,
            else => ui.Style.dim ++ ui.Style.pending ++ ui.Style.reset,
        };

        ui.print("  {s} {s}{s}{s} ({s})\n", .{
            icon,
            ui.Style.bold,
            rv.author,
            ui.Style.reset,
            rv.state.toString(),
        });
        if (rv.body) |body| {
            ui.print("    {s}\n", .{body});
        }
        ui.print("\n", .{});
    }

    // Print inline comments
    for (summary.comments) |comment| {
        ui.print("  {s}▸{s} {s}{s}{s}", .{
            ui.Style.yellow,
            ui.Style.reset,
            ui.Style.bold,
            comment.author,
            ui.Style.reset,
        });
        if (comment.path) |path| {
            if (comment.line) |line| {
                ui.print(" on {s}{s}:{d}{s}", .{ ui.Style.dim, path, line, ui.Style.reset });
            } else {
                ui.print(" on {s}{s}{s}", .{ ui.Style.dim, path, ui.Style.reset });
            }
        }
        ui.print("\n", .{});
        ui.print("    {s}\n\n", .{comment.body});
    }

    ui.print("  {s}Total: {d} feedback item{s}{s}\n\n", .{
        ui.Style.dim,
        summary.feedbackCount(),
        if (summary.feedbackCount() == 1) "" else "s",
        ui.Style.reset,
    });
}

fn runReviewTUISingle(allocator: std.mem.Allocator, summary: *review.PRReviewSummary) void {
    // Set up context for copy callback
    ReviewTUIState.pr_context = prompt.PromptContext{
        .pr_title = summary.pr_title,
        .pr_number = summary.pr_number,
        .branch = summary.branch,
    };

    // Build items using shared function
    ReviewTUIState.buildItemsForSummary(summary);

    if (ReviewTUIState.tui_items.items.len == 0) {
        ui.print("\n  {s}No review feedback yet.{s}\n\n", .{ ui.Style.dim, ui.Style.reset });
        return;
    }

    // Create single PR info for header display
    var single_pr_info = [_]tui.PRInfo{.{
        .number = summary.pr_number,
        .title = summary.pr_title,
    }};

    var current_index: usize = 0;

    tui.runInteractive(
        allocator,
        ReviewTUIState.tui_items.items,
        ReviewTUIState.copyCallback,
        &single_pr_info,
        &current_index,
        null, // No PR change callback for single PR mode
    ) catch |err| {
        ui.printError("TUI error: {any}\n", .{err});
    };
}

fn cmdOpen(allocator: std.mem.Allocator) void {
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
        ui.print("No commits in stack.\n", .{});
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
        for (specs) |*spec| {
            var s = spec.*;
            s.deinit(allocator);
        }
        allocator.free(specs);
    }

    const OpenablePR = struct {
        number: u32,
        title: []const u8,
        url: []const u8,
    };

    var prs = std.ArrayListUnmanaged(OpenablePR){};
    defer {
        for (prs.items) |pr| {
            allocator.free(pr.url);
        }
        prs.deinit(allocator);
    }

    for (specs, 0..) |spec, idx| {
        if (spec.is_wip) continue;

        if (gh_client.findPR(spec.branch_name) catch null) |pr| {
            var mutable_pr = pr;
            defer mutable_pr.deinit(allocator);

            if (std.mem.eql(u8, pr.state, "closed")) continue;

            const url_copy = allocator.dupe(u8, pr.html_url) catch continue;
            prs.append(allocator, .{
                .number = pr.number,
                .title = stk.commits[idx].title,
                .url = url_copy,
            }) catch {
                allocator.free(url_copy);
                continue;
            };
        }
    }

    if (prs.items.len == 0) {
        ui.print("No PRs found. Run 'ztk update' first.\n", .{});
        return;
    }

    if (prs.items.len == 1) {
        const pr = prs.items[0];
        ui.print("\n  Opening PR #{d}: {s}\n\n", .{ pr.number, pr.title });
        openUrl(allocator, pr.url);
        return;
    }

    // Multiple PRs - show selector
    ui.print("\n  Select a PR to open:\n\n", .{});

    for (prs.items, 0..) |pr, idx| {
        const num = idx + 1;
        ui.print("    {s}[{d}]{s} {s}#{d}{s} {s}\n", .{
            ui.Style.dim,
            num,
            ui.Style.reset,
            ui.Style.blue,
            pr.number,
            ui.Style.reset,
            pr.title,
        });
    }

    ui.print("\n", .{});
    ui.print("  PR to open (1-{d}): ", .{prs.items.len});

    var input_buf: [32]u8 = undefined;
    var input_len: usize = 0;
    const stdin_fd = std.posix.STDIN_FILENO;
    while (input_len < input_buf.len) {
        const bytes_read = std.posix.read(stdin_fd, input_buf[input_len..]) catch {
            ui.printError("Failed to read input\n", .{});
            return;
        };
        if (bytes_read == 0) break;
        input_len += bytes_read;
        if (std.mem.indexOfScalar(u8, input_buf[0..input_len], '\n')) |_| break;
    }
    const input: ?[]const u8 = if (input_len > 0) input_buf[0..input_len] else null;

    if (input == null) {
        ui.print("\n  Cancelled.\n\n", .{});
        return;
    }

    const trimmed = std.mem.trim(u8, input.?, " \r\t\n");
    if (trimmed.len == 0) {
        ui.print("  Cancelled.\n\n", .{});
        return;
    }

    const pr_num = std.fmt.parseInt(usize, trimmed, 10) catch {
        ui.printError("Invalid input. Enter a number.\n", .{});
        return;
    };

    if (pr_num < 1 or pr_num > prs.items.len) {
        ui.printError("Invalid PR number: {d}. Must be between 1 and {d}.\n", .{ pr_num, prs.items.len });
        return;
    }

    const selected_pr = prs.items[pr_num - 1];
    ui.print("\n  Opening PR #{d}: {s}\n\n", .{ selected_pr.number, selected_pr.title });
    openUrl(allocator, selected_pr.url);
}

fn openUrl(allocator: std.mem.Allocator, url: []const u8) void {
    // Try platform-specific commands: macOS (open), Linux (xdg-open), WSL/fallback (wslview)
    const commands = [_][]const u8{ "open", "xdg-open", "wslview" };

    for (commands) |cmd| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ cmd, url },
        });
        if (result) |r| {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
            if (r.term.Exited == 0) return; // Success
        } else |_| {
            continue; // Command not found, try next
        }
    }

    // All commands failed - print URL for manual copy
    ui.printError("Could not open browser automatically.\n", .{});
    ui.print("  {s}\n", .{url});
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
        \\    update, push, u   Create/update pull requests for commits in the stack
        \\    sync              Fetch, rebase on main, and clean merged branches
        \\    modify            Amend a commit in the middle of the stack
        \\    absorb, a, ab     Auto-amend staged changes into relevant commits
        \\    merge, m          Merge all mergeable PRs (top PR targets main, lower PRs closed)
        \\    review, r, rv     View and copy PR review feedback (interactive TUI)
        \\    open, o           Open a PR in the browser
        \\    help, --help, -h  Show this help message
        \\
        \\MODIFY/ABSORB OPTIONS:
        \\    -u, --update      Run 'ztk update' after successful modify/absorb
        \\
        \\MERGE OPTIONS:
        \\    -i, --interactive Interactively select up to which PR to merge
        \\    -r, --rebase      Rebase current branch onto updated main after merge
        \\    -n, --no-review   Merge without requiring an approved review
        \\    -f, --force       Force merge (only blocked by merge conflicts)
        \\
        \\REVIEW OPTIONS:
        \\    --stack, -s       Show feedback for all PRs in stack (navigate with h/l)
        \\    --pr, -p <NUM>    Show feedback for specific PR number
        \\    --list, -l        Print feedback as a list (non-interactive)
        \\
        \\EXAMPLES:
        \\    ztk init          # Initialize ztk config
        \\    ztk status        # Show stack status
        \\    ztk update        # Sync stack to GitHub
        \\    ztk sync          # Rebase on main and clean up
        \\    ztk modify        # Amend a commit in the stack
        \\    ztk modify -u     # Amend and sync to GitHub
        \\    ztk absorb        # Auto-absorb staged changes
        \\    ztk absorb -u     # Absorb and sync to GitHub
        \\    ztk merge         # Merge ready PRs
        \\    ztk merge -i      # Interactively select which PRs to merge
        \\    ztk merge -r      # Merge and rebase local branch
        \\    ztk review        # Interactive review feedback TUI (current PR)
        \\    ztk review -s     # Review feedback for all PRs in stack
        \\    ztk review --list # Print feedback as list
        \\    ztk open          # Open a PR in the browser
        \\
    ;
    ui.print("{s}", .{usage});
}
