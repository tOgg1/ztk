const std = @import("std");
const git = @import("git.zig");
const cfg = @import("config.zig");

pub const Stack = struct {
    base_branch: []const u8,
    head_branch: []const u8,
    commits: []git.Commit,

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        allocator.free(self.base_branch);
        allocator.free(self.head_branch);
        for (self.commits) |*c| c.deinit(allocator);
        allocator.free(self.commits);
    }
};

pub const PRSpec = struct {
    sha: []const u8,
    branch_name: []const u8,
    base_ref: []const u8,
    title: []const u8,
    body: []const u8,
    is_wip: bool,
    ztk_id: ?[]const u8,
};

pub fn readStack(allocator: std.mem.Allocator, config: cfg.Config) !Stack {
    const current = try git.currentBranch(allocator);
    errdefer allocator.free(current);

    var base_buf: [256]u8 = undefined;
    const remote_base = std.fmt.bufPrint(&base_buf, "{s}/{s}", .{ config.remote, config.main_branch }) catch {
        return error.OutOfMemory;
    };

    const commits = git.commitRange(allocator, remote_base, "HEAD") catch |err| blk: {
        if (err == git.GitError.CommandFailed) {
            break :blk try git.commitRange(allocator, config.main_branch, "HEAD");
        }
        return err;
    };
    errdefer {
        for (commits) |*c| {
            var commit = c.*;
            commit.deinit(allocator);
        }
        allocator.free(commits);
    }

    const base_branch = try allocator.dupe(u8, config.main_branch);

    return Stack{
        .base_branch = base_branch,
        .head_branch = current,
        .commits = commits,
    };
}

pub fn derivePRSpecs(allocator: std.mem.Allocator, stk: Stack, config: cfg.Config) ![]PRSpec {
    var specs = std.ArrayListUnmanaged(PRSpec){};
    errdefer specs.deinit(allocator);

    var prev_branch: ?[]const u8 = null;

    for (stk.commits) |commit| {
        const id_suffix = if (commit.ztk_id) |id|
            id[0..@min(8, id.len)]
        else
            commit.short_sha;

        var branch_buf: [256]u8 = undefined;
        const branch_name = std.fmt.bufPrint(&branch_buf, "ztk/{s}/{s}", .{
            stk.head_branch,
            id_suffix,
        }) catch return error.OutOfMemory;

        const branch_copy = try allocator.dupe(u8, branch_name);
        errdefer allocator.free(branch_copy);

        const base_ref = if (prev_branch) |pb|
            try allocator.dupe(u8, pb)
        else
            try allocator.dupe(u8, config.main_branch);
        errdefer allocator.free(base_ref);

        try specs.append(allocator, .{
            .sha = commit.sha,
            .branch_name = branch_copy,
            .base_ref = base_ref,
            .title = commit.title,
            .body = commit.body,
            .is_wip = commit.is_wip,
            .ztk_id = commit.ztk_id,
        });

        if (prev_branch) |pb| allocator.free(pb);
        prev_branch = try allocator.dupe(u8, branch_name);
    }

    if (prev_branch) |pb| allocator.free(pb);

    return specs.toOwnedSlice(allocator);
}
