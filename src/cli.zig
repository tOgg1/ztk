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
    review_cmd,
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
            .{ "review", .review_cmd },
            .{ "r", .review_cmd },
            .{ "rv", .review_cmd },
            .{ "feedback", .review_cmd },
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
            .review_cmd => cmdReview(allocator, args),
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
    _ = allocator;
    ui.print("ztk update: not implemented\n", .{});
}

/// Feedback item for unified handling of reviews and comments
const FeedbackItem = union(enum) {
    review_item: *const review.Review,
    comment_item: *const review.ReviewComment,
};

fn cmdReview(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    // Parse flags
    var pr_number: ?u32 = null;
    var list_mode = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pr")) {
            if (i + 1 < args.len) {
                pr_number = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    ui.printError("Invalid PR number: {s}\n", .{args[i + 1]});
                    return;
                };
                i += 1;
            } else {
                ui.printError("--pr requires a number\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "--list") or std.mem.eql(u8, args[i], "-l")) {
            list_mode = true;
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
        switch (err) {
            github.GitHubError.NoToken => {
                ui.printError("GITHUB_TOKEN environment variable not set.\n", .{});
                ui.print("  Set it with: export GITHUB_TOKEN=<your-token>\n", .{});
            },
            else => {
                ui.printError("Failed to initialize GitHub client: {any}\n", .{err});
            },
        }
        return;
    };

    // If no PR specified, try to find PR for current branch
    const target_pr = if (pr_number) |n| n else blk: {
        const current_branch = git.currentBranch(allocator) catch {
            ui.printError("Could not get current branch.\n", .{});
            return;
        };
        defer allocator.free(current_branch);

        const pr = gh_client.findPR(current_branch) catch {
            ui.printError("Failed to find PR for branch: {s}\n", .{current_branch});
            return;
        };

        if (pr) |p| {
            defer {
                var pr_copy = p;
                pr_copy.deinit(allocator);
            }
            break :blk p.number;
        } else {
            ui.printError("No PR found for branch: {s}\n", .{current_branch});
            return;
        }
    };

    ui.print("\n  Fetching reviews for PR #{d}...\n\n", .{target_pr});

    const summary = gh_client.getPRReviewSummary(target_pr) catch |err| {
        ui.printError("Failed to fetch reviews: {any}\n", .{err});
        return;
    };
    defer {
        var s = summary;
        s.deinit(allocator);
    }

    // List mode: print and exit
    if (list_mode) {
        printReviewList(&summary);
        return;
    }

    // TUI mode: build list items and run interactive UI
    runReviewTUI(allocator, &summary);
}

fn printReviewList(summary: *const review.PRReviewSummary) void {
    // Display PR info
    ui.print("  {s}PR #{d}:{s} {s}\n", .{ ui.Style.bold, summary.pr_number, ui.Style.reset, summary.pr_title });
    ui.print("  {s}Branch:{s} {s}\n", .{ ui.Style.dim, ui.Style.reset, summary.branch });
    ui.print("  {s}URL:{s} {s}\n\n", .{ ui.Style.dim, ui.Style.reset, summary.pr_url });

    // Display reviews
    if (summary.reviews.len > 0) {
        ui.print("  {s}Reviews ({d}):{s}\n", .{ ui.Style.bold, summary.reviews.len, ui.Style.reset });
        for (summary.reviews) |r| {
            const state_icon = switch (r.state) {
                .approved => ui.Style.green ++ ui.Style.check ++ ui.Style.reset,
                .changes_requested => ui.Style.red ++ ui.Style.cross ++ ui.Style.reset,
                .commented => ui.Style.blue ++ "●" ++ ui.Style.reset,
                .dismissed => ui.Style.dim ++ "○" ++ ui.Style.reset,
                .pending => ui.Style.dim ++ ui.Style.pending ++ ui.Style.reset,
            };
            ui.print("    {s} {s} ({s})\n", .{ state_icon, r.author, r.state.toString() });
            if (r.body) |body| {
                var lines = std.mem.splitScalar(u8, body, '\n');
                if (lines.next()) |first_line| {
                    const preview = if (first_line.len > 60) first_line[0..60] else first_line;
                    ui.print("      {s}\"{s}...\"{s}\n", .{ ui.Style.dim, preview, ui.Style.reset });
                }
            }
        }
        ui.print("\n", .{});
    }

    // Display inline comments
    if (summary.comments.len > 0) {
        ui.print("  {s}Inline Comments ({d}):{s}\n", .{ ui.Style.bold, summary.comments.len, ui.Style.reset });
        for (summary.comments, 0..) |c, idx| {
            const path_display = c.path orelse "(general)";
            const line_display = if (c.line) |l| l else 0;

            ui.print("    {s}[{d}]{s} {s}:{d} - {s}@{s}{s}\n", .{
                ui.Style.yellow,
                idx + 1,
                ui.Style.reset,
                path_display,
                line_display,
                ui.Style.dim,
                c.author,
                ui.Style.reset,
            });

            const preview = if (c.body.len > 80) c.body[0..80] else c.body;
            var preview_buf: [100]u8 = undefined;
            var j: usize = 0;
            for (preview) |ch| {
                if (j >= preview_buf.len - 1) break;
                preview_buf[j] = if (ch == '\n' or ch == '\r') ' ' else ch;
                j += 1;
            }
            ui.print("        {s}{s}...{s}\n", .{ ui.Style.dim, preview_buf[0..j], ui.Style.reset });
        }
        ui.print("\n", .{});
    }

    if (summary.reviews.len == 0 and summary.comments.len == 0) {
        ui.print("  {s}No reviews or comments yet.{s}\n\n", .{ ui.Style.dim, ui.Style.reset });
    }

    ui.print("  {s}Total feedback items: {d}{s}\n\n", .{ ui.Style.dim, summary.feedbackCount(), ui.Style.reset });
}

fn runReviewTUI(allocator: std.mem.Allocator, summary: *const review.PRReviewSummary) void {
    // Build list items from reviews and comments
    const total_items = summary.reviews.len + summary.comments.len;
    if (total_items == 0) {
        ui.print("  {s}No feedback items to display.{s}\n\n", .{ ui.Style.dim, ui.Style.reset });
        return;
    }

    var list_items = allocator.alloc(tui.ListItem, total_items) catch {
        ui.printError("Out of memory\n", .{});
        return;
    };
    defer allocator.free(list_items);

    var feedback_refs = allocator.alloc(FeedbackItem, total_items) catch {
        ui.printError("Out of memory\n", .{});
        return;
    };
    defer allocator.free(feedback_refs);

    var idx: usize = 0;

    // Add reviews with bodies
    for (summary.reviews) |*r| {
        if (r.body == null and r.state == .pending) continue;

        const state_str = switch (r.state) {
            .approved => "APPROVED",
            .changes_requested => "CHANGES REQUESTED",
            .commented => "COMMENTED",
            .dismissed => "DISMISSED",
            .pending => "PENDING",
        };

        const item_type: tui.ItemType = switch (r.state) {
            .approved => .review_approved,
            .changes_requested => .review_changes_requested,
            .commented => .review_commented,
            else => .review_pending,
        };

        // Format primary line
        var primary_buf: [256]u8 = undefined;
        const primary = std.fmt.bufPrint(&primary_buf, "{s} - @{s}", .{ state_str, r.author }) catch "Review";

        // Store a copy for the list
        const primary_copy = allocator.dupe(u8, primary) catch continue;

        // Create a preview for secondary (first 60 chars of body)
        const secondary_copy: ?[]const u8 = if (r.body) |b| blk: {
            const preview_len = @min(b.len, 60);
            var preview_buf: [80]u8 = undefined;
            var j: usize = 0;
            for (b[0..preview_len]) |ch| {
                if (j >= preview_buf.len - 1) break;
                preview_buf[j] = if (ch == '\n' or ch == '\r') ' ' else ch;
                j += 1;
            }
            break :blk allocator.dupe(u8, preview_buf[0..j]) catch null;
        } else null;

        feedback_refs[idx] = .{ .review_item = r };
        list_items[idx] = .{
            .primary = primary_copy,
            .secondary = secondary_copy,
            .detail = r.body,
            .context = @ptrCast(@constCast(&feedback_refs[idx])),
            .item_type = item_type,
        };
        idx += 1;
    }

    // Add inline comments
    for (summary.comments) |*c| {
        const path_display = c.path orelse "(general)";

        // Format primary line
        var primary_buf: [256]u8 = undefined;
        const primary = if (c.line) |line|
            std.fmt.bufPrint(&primary_buf, "{s}:{d} - @{s}", .{ path_display, line, c.author }) catch "Comment"
        else
            std.fmt.bufPrint(&primary_buf, "{s} - @{s}", .{ path_display, c.author }) catch "Comment";

        const primary_copy = allocator.dupe(u8, primary) catch continue;

        // Create preview for secondary
        const preview_len = @min(c.body.len, 60);
        var preview_buf: [80]u8 = undefined;
        var j: usize = 0;
        for (c.body[0..preview_len]) |ch| {
            if (j >= preview_buf.len - 1) break;
            preview_buf[j] = if (ch == '\n' or ch == '\r') ' ' else ch;
            j += 1;
        }
        const secondary_copy = allocator.dupe(u8, preview_buf[0..j]) catch null;

        feedback_refs[idx] = .{ .comment_item = c };
        list_items[idx] = .{
            .primary = primary_copy,
            .secondary = secondary_copy,
            .detail = c.body,
            .context = @ptrCast(@constCast(&feedback_refs[idx])),
            .item_type = .comment,
        };
        idx += 1;
    }

    // Trim to actual count
    const items_slice = list_items[0..idx];

    // Run the TUI
    const result = tui.runInteractive(allocator, items_slice) catch |err| {
        ui.printError("TUI error: {any}\n", .{err});
        return;
    };

    // Handle action
    switch (result.action) {
        .quit => {
            ui.print("\n", .{});
        },
        .copy_raw, .copy_llm => {
            if (result.selected < idx) {
                const item = &feedback_refs[result.selected];
                const ctx = prompt.PromptContext{
                    .pr_title = summary.pr_title,
                    .pr_number = summary.pr_number,
                    .branch = summary.branch,
                };

                if (result.action == .copy_llm) {
                    // Copy with LLM instructions
                    const formatted = switch (item.*) {
                        .comment_item => |c| prompt.formatCommentFull(allocator, c.*, ctx) catch {
                            ui.printError("Failed to format comment\n", .{});
                            return;
                        },
                        .review_item => |r| prompt.formatReview(allocator, r.*, ctx) catch {
                            ui.printError("Failed to format review\n", .{});
                            return;
                        },
                    };
                    defer allocator.free(formatted);
                    clipboard.copyWithFeedback(allocator, formatted);
                } else {
                    // Copy raw text only
                    const raw_text = switch (item.*) {
                        .comment_item => |c| c.body,
                        .review_item => |r| r.body orelse "",
                    };
                    clipboard.copyWithFeedback(allocator, raw_text);
                }
            }
        },
    }

    // Clean up allocated strings
    for (items_slice) |item| {
        allocator.free(item.primary);
        if (item.secondary) |s| allocator.free(s);
    }
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
        \\    review, r, rv     View PR review feedback
        \\    help, --help, -h  Show this help message
        \\
        \\REVIEW OPTIONS:
        \\    --pr <number>     Show reviews for specific PR number
        \\    --list, -l        Show reviews as text list (non-interactive)
        \\
        \\EXAMPLES:
        \\    ztk init          # Initialize ztk config
        \\    ztk status        # Show stack status
        \\    ztk update        # Sync stack to GitHub
        \\    ztk review        # View PR feedback
        \\    ztk r --pr 123    # View feedback for PR #123
        \\
    ;
    ui.print("{s}", .{usage});
}
