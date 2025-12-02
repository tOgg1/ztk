const std = @import("std");

pub const Commit = struct {
    sha: []const u8,
    short_sha: []const u8,
    title: []const u8,
    body: []const u8,
    is_wip: bool,
    ztk_id: ?[]const u8,

    pub fn deinit(self: *Commit, allocator: std.mem.Allocator) void {
        allocator.free(self.sha);
        allocator.free(self.short_sha);
        allocator.free(self.title);
        allocator.free(self.body);
        if (self.ztk_id) |id| allocator.free(id);
    }
};

const ztk_id_prefix = "ztk-id: ";

pub fn parseZtkId(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, ztk_id_prefix)) {
            const id = trimmed[ztk_id_prefix.len..];
            if (id.len > 0) return id;
        }
    }
    return null;
}

pub fn generateZtkId(allocator: std.mem.Allocator) GitError![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var buf: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var idx: usize = 0;

    for (bytes[0..4]) |b| {
        buf[idx] = hex[b >> 4];
        buf[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }
    buf[idx] = '-';
    idx += 1;
    for (bytes[4..6]) |b| {
        buf[idx] = hex[b >> 4];
        buf[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }
    buf[idx] = '-';
    idx += 1;
    for (bytes[6..8]) |b| {
        buf[idx] = hex[b >> 4];
        buf[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }
    buf[idx] = '-';
    idx += 1;
    for (bytes[8..10]) |b| {
        buf[idx] = hex[b >> 4];
        buf[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }
    buf[idx] = '-';
    idx += 1;
    for (bytes[10..16]) |b| {
        buf[idx] = hex[b >> 4];
        buf[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }

    return allocator.dupe(u8, &buf) catch return GitError.OutOfMemory;
}

pub const GitError = error{
    CommandFailed,
    NotInGitRepo,
    OutOfMemory,
    ParseError,
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) GitError![]u8 {
    const argv_len = args.len + 1;
    var argv_buf: [32][]const u8 = undefined;
    if (argv_len > argv_buf.len) return GitError.OutOfMemory;

    argv_buf[0] = "git";
    for (args, 0..) |arg, i| {
        argv_buf[i + 1] = arg;
    }
    const argv = argv_buf[0..argv_len];

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return GitError.CommandFailed;

    var stdout_list = std.ArrayListUnmanaged(u8){};
    var stderr_list = std.ArrayListUnmanaged(u8){};
    defer stderr_list.deinit(allocator);

    child.collectOutput(allocator, &stdout_list, &stderr_list, 10 * 1024 * 1024) catch {
        stdout_list.deinit(allocator);
        return GitError.CommandFailed;
    };

    const result = child.wait() catch {
        stdout_list.deinit(allocator);
        return GitError.CommandFailed;
    };

    if (result.Exited != 0) {
        stdout_list.deinit(allocator);
        return GitError.CommandFailed;
    }

    return stdout_list.toOwnedSlice(allocator) catch return GitError.OutOfMemory;
}

pub fn runOrFail(allocator: std.mem.Allocator, args: []const []const u8) []u8 {
    return run(allocator, args) catch |err| {
        std.debug.panic("git command failed: {any}", .{err});
    };
}

pub fn currentBranch(allocator: std.mem.Allocator) GitError![]u8 {
    const output = try run(allocator, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer allocator.free(output);

    const trimmed = std.mem.trim(u8, output, "\n\r ");
    return allocator.dupe(u8, trimmed) catch return GitError.OutOfMemory;
}

pub fn repoRoot(allocator: std.mem.Allocator) GitError![]u8 {
    const output = try run(allocator, &.{ "rev-parse", "--show-toplevel" });
    defer allocator.free(output);

    const trimmed = std.mem.trim(u8, output, "\n\r ");
    return allocator.dupe(u8, trimmed) catch return GitError.OutOfMemory;
}

pub fn commitRange(allocator: std.mem.Allocator, base: []const u8, head: []const u8) GitError![]Commit {
    var range_buf: [256]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "{s}..{s}", .{ base, head }) catch return GitError.OutOfMemory;

    var format_buf: [64]u8 = undefined;
    const format = std.fmt.bufPrint(&format_buf, "--format=%H%x00%s%x00%b%x00", .{}) catch return GitError.OutOfMemory;

    const output = run(allocator, &.{ "log", "--reverse", format, range }) catch |err| {
        return err;
    };
    defer allocator.free(output);

    return parseCommits(allocator, output);
}

fn parseCommits(allocator: std.mem.Allocator, output: []const u8) GitError![]Commit {
    var commits = std.ArrayListUnmanaged(Commit){};
    errdefer {
        for (commits.items) |*c| c.deinit(allocator);
        commits.deinit(allocator);
    }

    var iter = std.mem.splitSequence(u8, output, "\x00");
    while (true) {
        const sha_raw = iter.next() orelse break;
        const trimmed_sha = std.mem.trim(u8, sha_raw, "\n\r ");
        if (trimmed_sha.len < 7) continue;

        const title = iter.next() orelse break;
        const body_raw = iter.next() orelse "";
        const body = std.mem.trim(u8, body_raw, "\n\r ");

        const short_sha = allocator.dupe(u8, trimmed_sha[0..7]) catch return GitError.OutOfMemory;
        errdefer allocator.free(short_sha);

        const sha_copy = allocator.dupe(u8, trimmed_sha) catch return GitError.OutOfMemory;
        errdefer allocator.free(sha_copy);

        const title_copy = allocator.dupe(u8, std.mem.trim(u8, title, "\n\r ")) catch return GitError.OutOfMemory;
        errdefer allocator.free(title_copy);

        const body_copy = allocator.dupe(u8, body) catch return GitError.OutOfMemory;
        errdefer allocator.free(body_copy);

        const is_wip = std.mem.startsWith(u8, title_copy, "WIP") or
            std.mem.indexOf(u8, title_copy, "[WIP]") != null;

        const ztk_id: ?[]const u8 = if (parseZtkId(body_copy)) |id|
            allocator.dupe(u8, id) catch return GitError.OutOfMemory
        else
            null;

        commits.append(allocator, .{
            .sha = sha_copy,
            .short_sha = short_sha,
            .title = title_copy,
            .body = body_copy,
            .is_wip = is_wip,
            .ztk_id = ztk_id,
        }) catch return GitError.OutOfMemory;
    }

    return commits.toOwnedSlice(allocator) catch return GitError.OutOfMemory;
}

pub fn ensureBranchAt(allocator: std.mem.Allocator, branch: []const u8, sha: []const u8) GitError!void {
    const output = run(allocator, &.{ "branch", "-f", branch, sha });
    if (output) |o| allocator.free(o) else |_| {}
}

pub fn push(allocator: std.mem.Allocator, remote: []const u8, branch: []const u8, force: bool) GitError!void {
    if (force) {
        const output = try run(allocator, &.{ "push", "--force", remote, branch });
        allocator.free(output);
    } else {
        const output = try run(allocator, &.{ "push", remote, branch });
        allocator.free(output);
    }
}

pub fn getRemoteUrl(allocator: std.mem.Allocator, remote: []const u8) GitError![]u8 {
    const output = try run(allocator, &.{ "remote", "get-url", remote });
    defer allocator.free(output);

    const trimmed = std.mem.trim(u8, output, "\n\r ");
    return allocator.dupe(u8, trimmed) catch return GitError.OutOfMemory;
}

pub const RepoInfo = struct {
    owner: []const u8,
    repo: []const u8,

    pub fn deinit(self: *RepoInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
    }
};

pub fn parseGitHubRemote(allocator: std.mem.Allocator, url: []const u8) GitError!RepoInfo {
    var owner: []const u8 = undefined;
    var repo: []const u8 = undefined;

    if (std.mem.startsWith(u8, url, "git@github.com:")) {
        const path = url["git@github.com:".len..];
        var parts = std.mem.splitScalar(u8, path, '/');
        owner = parts.next() orelse return GitError.ParseError;
        const repo_with_git = parts.next() orelse return GitError.ParseError;
        repo = if (std.mem.endsWith(u8, repo_with_git, ".git"))
            repo_with_git[0 .. repo_with_git.len - 4]
        else
            repo_with_git;
    } else if (std.mem.startsWith(u8, url, "https://github.com/")) {
        const path = url["https://github.com/".len..];
        var parts = std.mem.splitScalar(u8, path, '/');
        owner = parts.next() orelse return GitError.ParseError;
        const repo_with_git = parts.next() orelse return GitError.ParseError;
        repo = if (std.mem.endsWith(u8, repo_with_git, ".git"))
            repo_with_git[0 .. repo_with_git.len - 4]
        else
            repo_with_git;
    } else {
        return GitError.ParseError;
    }

    const owner_copy = allocator.dupe(u8, owner) catch return GitError.OutOfMemory;
    errdefer allocator.free(owner_copy);
    const repo_copy = allocator.dupe(u8, repo) catch return GitError.OutOfMemory;

    return RepoInfo{
        .owner = owner_copy,
        .repo = repo_copy,
    };
}

pub fn getCommitMessage(allocator: std.mem.Allocator, sha: []const u8) GitError![]u8 {
    const output = try run(allocator, &.{ "log", "-1", "--format=%B", sha });
    return output;
}

pub fn amendCommitMessage(allocator: std.mem.Allocator, new_message: []const u8) GitError!void {
    const output = run(allocator, &.{ "commit", "--amend", "-m", new_message });
    if (output) |o| allocator.free(o) else |_| {}
}

pub fn getMergeBase(allocator: std.mem.Allocator, ref1: []const u8, ref2: []const u8) GitError![]u8 {
    const output = try run(allocator, &.{ "merge-base", ref1, ref2 });
    defer allocator.free(output);
    const trimmed = std.mem.trim(u8, output, "\n\r ");
    return allocator.dupe(u8, trimmed) catch return GitError.OutOfMemory;
}

pub fn stash(allocator: std.mem.Allocator) GitError!bool {
    const before_output = run(allocator, &.{ "stash", "list" }) catch return GitError.CommandFailed;
    defer allocator.free(before_output);
    const before_count = std.mem.count(u8, before_output, "\n");

    const output = run(allocator, &.{"stash"});
    if (output) |o| allocator.free(o) else |_| return GitError.CommandFailed;

    const after_output = run(allocator, &.{ "stash", "list" }) catch return GitError.CommandFailed;
    defer allocator.free(after_output);
    const after_count = std.mem.count(u8, after_output, "\n");

    return after_count > before_count;
}

pub fn stashPop(allocator: std.mem.Allocator) GitError!void {
    const output = run(allocator, &.{ "stash", "pop" });
    if (output) |o| allocator.free(o) else |_| {}
}

pub fn fetch(allocator: std.mem.Allocator, remote: []const u8) GitError!void {
    const output = run(allocator, &.{ "fetch", remote });
    if (output) |o| allocator.free(o) else |_| return GitError.CommandFailed;
}

pub fn rebaseOnto(allocator: std.mem.Allocator, target: []const u8) GitError!void {
    const output = run(allocator, &.{ "rebase", "--autostash", target });
    if (output) |o| allocator.free(o) else |_| return GitError.CommandFailed;
}

pub fn listBranches(allocator: std.mem.Allocator, pattern: []const u8) GitError![][]const u8 {
    const output = run(allocator, &.{ "branch", "--list", pattern, "--format=%(refname:short)" }) catch {
        return GitError.CommandFailed;
    };
    defer allocator.free(output);

    var branches = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (branches.items) |b| allocator.free(b);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const branch_copy = allocator.dupe(u8, trimmed) catch return GitError.OutOfMemory;
        branches.append(allocator, branch_copy) catch {
            allocator.free(branch_copy);
            return GitError.OutOfMemory;
        };
    }

    return branches.toOwnedSlice(allocator) catch return GitError.OutOfMemory;
}

pub fn deleteBranch(allocator: std.mem.Allocator, branch: []const u8, force: bool) GitError!void {
    const flag = if (force) "-D" else "-d";
    const output = run(allocator, &.{ "branch", flag, branch });
    if (output) |o| allocator.free(o) else |_| return GitError.CommandFailed;
}

pub fn deleteRemoteBranch(allocator: std.mem.Allocator, remote: []const u8, branch: []const u8) GitError!void {
    var ref_buf: [256]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buf, ":{s}", .{branch}) catch return GitError.OutOfMemory;
    const output = run(allocator, &.{ "push", remote, ref });
    if (output) |o| allocator.free(o) else |_| return GitError.CommandFailed;
}
