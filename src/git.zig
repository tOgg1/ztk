const std = @import("std");

pub const Commit = struct {
    sha: []const u8,
    short_sha: []const u8,
    title: []const u8,
    body: []const u8,
    is_wip: bool,

    pub fn deinit(self: *Commit, allocator: std.mem.Allocator) void {
        allocator.free(self.sha);
        allocator.free(self.short_sha);
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

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

        commits.append(allocator, .{
            .sha = sha_copy,
            .short_sha = short_sha,
            .title = title_copy,
            .body = body_copy,
            .is_wip = is_wip,
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
