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
    owns_body: bool,

    pub fn deinit(self: *PRSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.branch_name);
        allocator.free(self.base_ref);
        if (self.owns_body) allocator.free(self.body);
    }
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
    errdefer {
        for (specs.items) |*spec| {
            spec.deinit(allocator);
        }
        specs.deinit(allocator);
    }

    var prev_branch: ?[]const u8 = null;
    defer if (prev_branch) |pb| allocator.free(pb);

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

        var branch_copy: ?[]const u8 = try allocator.dupe(u8, branch_name);
        errdefer if (branch_copy) |bc| allocator.free(bc);

        var base_ref: ?[]const u8 = if (prev_branch) |pb|
            try allocator.dupe(u8, pb)
        else
            try allocator.dupe(u8, config.main_branch);
        errdefer if (base_ref) |br| allocator.free(br);

        // Construct PR body with full commit message (title + body)
        // Note: commit.body already contains the ztk-id line, so we don't append it separately
        var pr_body: ?[]u8 = blk: {
            // Calculate total size needed
            var total_len: usize = commit.title.len;
            if (commit.body.len > 0) {
                total_len += 2 + commit.body.len; // "\n\n" + body
            }

            var body_buf = allocator.alloc(u8, total_len) catch return error.OutOfMemory;
            errdefer allocator.free(body_buf);

            var pos: usize = 0;

            // Add title
            @memcpy(body_buf[pos .. pos + commit.title.len], commit.title);
            pos += commit.title.len;

            // Add body if present (includes ztk-id line)
            if (commit.body.len > 0) {
                @memcpy(body_buf[pos .. pos + 2], "\n\n");
                pos += 2;
                @memcpy(body_buf[pos .. pos + commit.body.len], commit.body);
                pos += commit.body.len;
            }

            break :blk body_buf;
        };
        errdefer if (pr_body) |pb| allocator.free(pb);

        try specs.append(allocator, .{
            .sha = commit.sha,
            .branch_name = branch_copy.?,
            .base_ref = base_ref.?,
            .title = commit.title,
            .body = pr_body.?,
            .is_wip = commit.is_wip,
            .ztk_id = commit.ztk_id,
            .owns_body = true,
        });

        // Ownership transferred to specs - clear locals to prevent errdefer double-free
        branch_copy = null;
        base_ref = null;
        pr_body = null;

        if (prev_branch) |pb| allocator.free(pb);
        prev_branch = null; // Prevent double-free if next allocation fails
        prev_branch = try allocator.dupe(u8, branch_name);
    }

    return specs.toOwnedSlice(allocator);
}
