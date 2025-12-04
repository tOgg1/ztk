const std = @import("std");
const review = @import("review.zig");
const config = @import("config.zig");

pub const CheckStatus = enum {
    pending,
    success,
    failure,
    unknown,

    pub fn icon(self: CheckStatus) []const u8 {
        return switch (self) {
            .pending => "⏳",
            .success => "✓",
            .failure => "✗",
            .unknown => "?",
        };
    }

    pub fn color(self: CheckStatus) []const u8 {
        return switch (self) {
            .pending => "\x1b[33m",
            .success => "\x1b[32m",
            .failure => "\x1b[31m",
            .unknown => "\x1b[2m",
        };
    }
};

pub const ReviewStatus = enum {
    pending,
    approved,
    changes_requested,
    unknown,

    pub fn icon(self: ReviewStatus) []const u8 {
        return switch (self) {
            .pending => "⏳",
            .approved => "✓",
            .changes_requested => "✗",
            .unknown => "?",
        };
    }

    pub fn color(self: ReviewStatus) []const u8 {
        return switch (self) {
            .pending => "\x1b[33m",
            .approved => "\x1b[32m",
            .changes_requested => "\x1b[31m",
            .unknown => "\x1b[2m",
        };
    }

    pub fn label(self: ReviewStatus) []const u8 {
        return switch (self) {
            .pending => "Review",
            .approved => "Approved",
            .changes_requested => "Changes",
            .unknown => "Review",
        };
    }
};

pub const MergeableStatus = enum {
    mergeable,
    conflicting,
    unknown,

    pub fn icon(self: MergeableStatus) []const u8 {
        return switch (self) {
            .mergeable => "✓",
            .conflicting => "⚠",
            .unknown => "?",
        };
    }

    pub fn color(self: MergeableStatus) []const u8 {
        return switch (self) {
            .mergeable => "\x1b[32m",
            .conflicting => "\x1b[33m",
            .unknown => "\x1b[2m",
        };
    }
};

pub const PRStatus = struct {
    checks: CheckStatus,
    review: ReviewStatus,
    mergeable: MergeableStatus,
};

pub const PullRequest = struct {
    number: u32,
    html_url: []const u8,
    state: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
    title: []const u8,
    body: []const u8,
    head_sha: []const u8,
    mergeable: ?bool,

    pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.html_url);
        allocator.free(self.state);
        allocator.free(self.head_ref);
        allocator.free(self.base_ref);
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.head_sha);
    }
};

pub const GitHubError = error{
    NoToken,
    RequestFailed,
    ParseError,
    OutOfMemory,
    NotFound,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    owner: []const u8,
    repo: []const u8,
    owns_token: bool,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) GitHubError!Client {
        if (std.posix.getenv("GITHUB_TOKEN")) |env_token| {
            return Client{
                .allocator = allocator,
                .token = env_token,
                .owner = cfg.owner,
                .repo = cfg.repo,
                .owns_token = false,
            };
        }

        const gh_token = getGhAuthToken(allocator) catch return GitHubError.NoToken;
        return Client{
            .allocator = allocator,
            .token = gh_token,
            .owner = cfg.owner,
            .repo = cfg.repo,
            .owns_token = true,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.owns_token) {
            self.allocator.free(self.token);
        }
    }

    fn getGhAuthToken(allocator: std.mem.Allocator) ![]const u8 {
        var child = std.process.Child.init(&.{ "gh", "auth", "token" }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch return error.NoToken;

        var stdout_list = std.ArrayListUnmanaged(u8){};
        var stderr_list = std.ArrayListUnmanaged(u8){};
        defer stderr_list.deinit(allocator);

        child.collectOutput(allocator, &stdout_list, &stderr_list, 1024 * 1024) catch {
            stdout_list.deinit(allocator);
            return error.NoToken;
        };

        const result = child.wait() catch {
            stdout_list.deinit(allocator);
            return error.NoToken;
        };

        if (result.Exited != 0) {
            stdout_list.deinit(allocator);
            return error.NoToken;
        }

        const output = stdout_list.toOwnedSlice(allocator) catch return error.NoToken;
        const trimmed = std.mem.trim(u8, output, "\n\r ");
        const token_result = allocator.dupe(u8, trimmed) catch {
            allocator.free(output);
            return error.NoToken;
        };
        allocator.free(output);
        return token_result;
    }

    pub fn findPR(self: *Client, head_branch: []const u8) GitHubError!?PullRequest {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls?head={s}:{s}&state=open", .{
            self.owner,
            self.repo,
            self.owner,
            head_branch,
        }) catch return GitHubError.OutOfMemory;

        const response = self.request("GET", path, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .array) return GitHubError.ParseError;
        const array = parsed.value.array;
        if (array.items.len == 0) return null;

        const pr = array.items[0].object;
        const result = self.parsePR(pr) catch return GitHubError.ParseError;
        return result;
    }

    pub fn createPR(self: *Client, head: []const u8, base: []const u8, title: []const u8, body: []const u8) GitHubError!PullRequest {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls", .{
            self.owner,
            self.repo,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&json_buf);
        var writer = fbs.writer();

        writer.writeAll("{") catch return GitHubError.OutOfMemory;
        writer.writeAll("\"title\":") catch return GitHubError.OutOfMemory;
        writeJsonString(writer, title) catch return GitHubError.OutOfMemory;
        writer.writeAll(",\"body\":") catch return GitHubError.OutOfMemory;
        writeJsonString(writer, body) catch return GitHubError.OutOfMemory;
        writer.writeAll(",\"head\":") catch return GitHubError.OutOfMemory;
        writeJsonString(writer, head) catch return GitHubError.OutOfMemory;
        writer.writeAll(",\"base\":") catch return GitHubError.OutOfMemory;
        writeJsonString(writer, base) catch return GitHubError.OutOfMemory;
        writer.writeAll("}") catch return GitHubError.OutOfMemory;

        const json_body = fbs.getWritten();

        const response = self.request("POST", path, json_body) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return GitHubError.ParseError;
        }
        if (parsed.value.object.get("message")) |_| {
            return GitHubError.RequestFailed;
        }
        if (parsed.value.object.get("number") == null) {
            return GitHubError.RequestFailed;
        }

        return self.parsePR(parsed.value.object);
    }

    pub fn updatePR(self: *Client, pr_number: u32, title: ?[]const u8, body: ?[]const u8, base: ?[]const u8) GitHubError!void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&json_buf);
        var writer = fbs.writer();

        writer.writeAll("{") catch return GitHubError.OutOfMemory;
        var first = true;

        if (title) |t| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.writeAll("\"title\":") catch return GitHubError.OutOfMemory;
            writeJsonString(writer, t) catch return GitHubError.OutOfMemory;
            first = false;
        }
        if (body) |b| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.writeAll("\"body\":") catch return GitHubError.OutOfMemory;
            writeJsonString(writer, b) catch return GitHubError.OutOfMemory;
            first = false;
        }
        if (base) |bs| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.writeAll("\"base\":") catch return GitHubError.OutOfMemory;
            writeJsonString(writer, bs) catch return GitHubError.OutOfMemory;
            first = false;
        }

        writer.writeAll("}") catch return GitHubError.OutOfMemory;

        const response = self.request("PATCH", path, fbs.getWritten()) catch return GitHubError.RequestFailed;
        self.allocator.free(response);
    }

    fn writeJsonString(writer: anytype, str: []const u8) !void {
        try writer.writeByte('"');
        for (str) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }

    pub fn createOrUpdatePR(self: *Client, head: []const u8, base: []const u8, title: []const u8, body: []const u8) GitHubError!PullRequest {
        if (try self.findPR(head)) |existing| {
            const pr = existing;
            try self.updatePR(pr.number, title, body, base);
            return pr;
        }
        return try self.createPR(head, base, title, body);
    }

    pub fn getCheckStatus(self: *Client, sha: []const u8) CheckStatus {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/commits/{s}/check-runs", .{
            self.owner,
            self.repo,
            sha,
        }) catch return .unknown;

        const response = self.request("GET", path, null) catch return .unknown;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return .unknown;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const check_runs = obj.get("check_runs") orelse return .unknown;
        const runs = check_runs.array.items;

        if (runs.len == 0) return .pending;

        var has_pending = false;
        var has_failure = false;

        for (runs) |run| {
            const run_obj = run.object;
            const status = run_obj.get("status") orelse continue;
            const conclusion = run_obj.get("conclusion");

            if (!std.mem.eql(u8, status.string, "completed")) {
                has_pending = true;
                continue;
            }

            if (conclusion) |c| {
                if (c == .null) {
                    has_pending = true;
                } else if (std.mem.eql(u8, c.string, "success") or std.mem.eql(u8, c.string, "skipped") or std.mem.eql(u8, c.string, "neutral")) {
                    // success
                } else {
                    has_failure = true;
                }
            }
        }

        if (has_failure) return .failure;
        if (has_pending) return .pending;
        return .success;
    }

    pub fn getReviewStatus(self: *Client, pr_number: u32) ReviewStatus {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}/reviews", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return .unknown;

        const response = self.request("GET", path, null) catch return .unknown;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return .unknown;
        };
        defer parsed.deinit();

        const reviews = parsed.value.array.items;
        if (reviews.len == 0) return .pending;

        var latest_by_user = std.StringHashMap([]const u8).init(self.allocator);
        defer latest_by_user.deinit();

        for (reviews) |rv| {
            const review_obj = rv.object;
            const user_obj = review_obj.get("user") orelse continue;
            const login = user_obj.object.get("login") orelse continue;
            const state = review_obj.get("state") orelse continue;

            if (std.mem.eql(u8, state.string, "APPROVED") or
                std.mem.eql(u8, state.string, "CHANGES_REQUESTED"))
            {
                latest_by_user.put(login.string, state.string) catch continue;
            }
        }

        var has_approval = false;
        var has_changes_requested = false;
        var iter = latest_by_user.valueIterator();
        while (iter.next()) |state| {
            if (std.mem.eql(u8, state.*, "APPROVED")) {
                has_approval = true;
            } else if (std.mem.eql(u8, state.*, "CHANGES_REQUESTED")) {
                has_changes_requested = true;
            }
        }

        if (has_changes_requested) return .changes_requested;
        if (has_approval) return .approved;
        return .pending;
    }

    pub fn getPRStatus(self: *Client, pr: PullRequest) PRStatus {
        return PRStatus{
            .checks = self.getCheckStatus(pr.head_sha),
            .review = self.getReviewStatus(pr.number),
            .mergeable = if (pr.mergeable) |m|
                if (m) .mergeable else .conflicting
            else
                .unknown,
        };
    }

    pub fn isPRMerged(self: *Client, head_branch: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls?head={s}:{s}&state=all", .{
            self.owner,
            self.repo,
            self.owner,
            head_branch,
        }) catch return false;

        const response = self.request("GET", path, null) catch return false;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return false;
        };
        defer parsed.deinit();

        if (parsed.value != .array) return false;
        const array = parsed.value.array;
        if (array.items.len == 0) return false;

        const pr = array.items[0].object;
        const merged_at = pr.get("merged_at") orelse return false;
        return merged_at != .null;
    }

    /// Fetch all reviews for a PR
    pub fn listReviews(self: *Client, pr_number: u32) GitHubError![]review.Review {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}/reviews", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.request("GET", path, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        // Validate that response is an array
        if (parsed.value != .array) return GitHubError.ParseError;
        const array = parsed.value.array;
        var reviews: std.ArrayListUnmanaged(review.Review) = .empty;
        errdefer {
            for (reviews.items) |*r| {
                r.deinit(self.allocator);
            }
            reviews.deinit(self.allocator);
        }

        for (array.items) |item| {
            const obj = item.object;

            const state_str = obj.get("state").?.string;
            const state = review.ReviewState.fromString(state_str) orelse continue;

            // Skip pending reviews
            if (state == .pending) continue;

            const id = @as(u64, @intCast(obj.get("id").?.integer));

            const user_obj = obj.get("user").?.object;
            const author = self.allocator.dupe(u8, user_obj.get("login").?.string) catch return GitHubError.OutOfMemory;
            errdefer self.allocator.free(author);

            const submitted_at_val = obj.get("submitted_at");
            const submitted_at = if (submitted_at_val) |v|
                if (v == .string) self.allocator.dupe(u8, v.string) catch return GitHubError.OutOfMemory else self.allocator.dupe(u8, "") catch return GitHubError.OutOfMemory
            else
                self.allocator.dupe(u8, "") catch return GitHubError.OutOfMemory;
            errdefer self.allocator.free(submitted_at);

            const body_val = obj.get("body");
            const body_text: ?[]const u8 = if (body_val) |v| switch (v) {
                .string => |s| if (s.len > 0) self.allocator.dupe(u8, s) catch return GitHubError.OutOfMemory else null,
                else => null,
            } else null;
            errdefer if (body_text) |b| self.allocator.free(b);

            reviews.append(self.allocator, .{
                .id = id,
                .state = state,
                .body = body_text,
                .author = author,
                .submitted_at = submitted_at,
            }) catch return GitHubError.OutOfMemory;
        }

        return reviews.toOwnedSlice(self.allocator) catch return GitHubError.OutOfMemory;
    }

    /// Fetch all review comments (inline comments) for a PR
    pub fn listReviewComments(self: *Client, pr_number: u32) GitHubError![]review.ReviewComment {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}/comments", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.request("GET", path, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        // Validate that response is an array
        if (parsed.value != .array) return GitHubError.ParseError;
        const array = parsed.value.array;
        var comments: std.ArrayListUnmanaged(review.ReviewComment) = .empty;
        errdefer {
            for (comments.items) |*c| {
                c.deinit(self.allocator);
            }
            comments.deinit(self.allocator);
        }

        for (array.items) |item| {
            const obj = item.object;

            const id = @as(u64, @intCast(obj.get("id").?.integer));

            const body_val = obj.get("body").?;
            const body = self.allocator.dupe(u8, body_val.string) catch return GitHubError.OutOfMemory;
            errdefer self.allocator.free(body);

            const path_val = obj.get("path");
            const file_path: ?[]const u8 = if (path_val) |v| switch (v) {
                .string => |s| self.allocator.dupe(u8, s) catch return GitHubError.OutOfMemory,
                else => null,
            } else null;
            errdefer if (file_path) |p| self.allocator.free(p);

            const line_val = obj.get("line");
            const line: ?u32 = if (line_val) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            } else null;

            const original_line_val = obj.get("original_line");
            const original_line: ?u32 = if (original_line_val) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            } else null;

            const diff_hunk_val = obj.get("diff_hunk");
            const diff_hunk: ?[]const u8 = if (diff_hunk_val) |v| switch (v) {
                .string => |s| self.allocator.dupe(u8, s) catch return GitHubError.OutOfMemory,
                else => null,
            } else null;
            errdefer if (diff_hunk) |d| self.allocator.free(d);

            const user_obj = obj.get("user").?.object;
            const author = self.allocator.dupe(u8, user_obj.get("login").?.string) catch return GitHubError.OutOfMemory;
            errdefer self.allocator.free(author);

            const created_at = self.allocator.dupe(u8, obj.get("created_at").?.string) catch return GitHubError.OutOfMemory;
            errdefer self.allocator.free(created_at);

            const in_reply_to_val = obj.get("in_reply_to_id");
            const in_reply_to_id: ?u64 = if (in_reply_to_val) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            } else null;

            comments.append(self.allocator, .{
                .id = id,
                .body = body,
                .path = file_path,
                .line = line,
                .original_line = original_line,
                .diff_hunk = diff_hunk,
                .author = author,
                .created_at = created_at,
                .in_reply_to_id = in_reply_to_id,
            }) catch return GitHubError.OutOfMemory;
        }

        return comments.toOwnedSlice(self.allocator) catch return GitHubError.OutOfMemory;
    }

    /// Get a PR by number
    pub fn getPR(self: *Client, pr_number: u32) GitHubError!PullRequest {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.request("GET", path, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        return self.parsePR(parsed.value.object);
    }

    /// Fetch complete review summary for a PR (reviews + inline comments)
    pub fn getPRReviewSummary(self: *Client, pr_number: u32) GitHubError!review.PRReviewSummary {
        // Fetch PR details
        const pr = try self.getPR(pr_number);
        errdefer {
            var p = pr;
            p.deinit(self.allocator);
        }

        // Fetch reviews
        const reviews = try self.listReviews(pr_number);
        errdefer {
            for (reviews) |*r| {
                var rv = r;
                rv.deinit(self.allocator);
            }
            self.allocator.free(reviews);
        }

        // Fetch inline comments
        const comments = try self.listReviewComments(pr_number);
        errdefer {
            for (comments) |*c| {
                var cm = c;
                cm.deinit(self.allocator);
            }
            self.allocator.free(comments);
        }

        // Duplicate strings we need to keep (PR struct will be freed)
        const pr_title = self.allocator.dupe(u8, pr.title) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(pr_title);

        const pr_url = self.allocator.dupe(u8, pr.html_url) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(pr_url);

        const branch = self.allocator.dupe(u8, pr.head_ref) catch return GitHubError.OutOfMemory;

        // Clean up PR now that we've copied what we need
        var p = pr;
        p.deinit(self.allocator);

        return .{
            .pr_number = pr_number,
            .pr_title = pr_title,
            .pr_url = pr_url,
            .branch = branch,
            .reviews = reviews,
            .comments = comments,
        };
    }

    fn parsePR(self: *Client, obj: std.json.ObjectMap) GitHubError!PullRequest {
        const number = @as(u32, @intCast(obj.get("number").?.integer));

        const html_url = self.allocator.dupe(u8, obj.get("html_url").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(html_url);

        const state = self.allocator.dupe(u8, obj.get("state").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(state);

        const head_obj = obj.get("head").?.object;
        const head_ref = self.allocator.dupe(u8, head_obj.get("ref").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(head_ref);

        const head_sha = self.allocator.dupe(u8, head_obj.get("sha").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(head_sha);

        const base_obj = obj.get("base").?.object;
        const base_ref = self.allocator.dupe(u8, base_obj.get("ref").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(base_ref);

        const title = self.allocator.dupe(u8, obj.get("title").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(title);

        const body_val = obj.get("body");
        const body = if (body_val) |bv| switch (bv) {
            .string => |s| self.allocator.dupe(u8, s) catch return GitHubError.OutOfMemory,
            else => self.allocator.dupe(u8, "") catch return GitHubError.OutOfMemory,
        } else self.allocator.dupe(u8, "") catch return GitHubError.OutOfMemory;

        const mergeable: ?bool = if (obj.get("mergeable")) |m| switch (m) {
            .bool => |b| b,
            else => null,
        } else null;

        return PullRequest{
            .number = number,
            .html_url = html_url,
            .state = state,
            .head_ref = head_ref,
            .base_ref = base_ref,
            .title = title,
            .body = body,
            .head_sha = head_sha,
            .mergeable = mergeable,
        };
    }

    pub fn mergePR(self: *Client, pr_number: u32) !void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}/merge", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return error.OutOfMemory;

        const body = "{\"merge_method\":\"rebase\"}";
        const response = try self.request("PUT", path, body);
        defer self.allocator.free(response);
    }

    pub fn closePR(self: *Client, pr_number: u32) !void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return error.OutOfMemory;

        const body = "{\"state\":\"closed\"}";
        const response = try self.request("PATCH", path, body);
        defer self.allocator.free(response);
    }

    pub fn commentPR(self: *Client, pr_number: u32, comment: []const u8) !void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues/{d}/comments", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return error.OutOfMemory;

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"body\":\"{s}\"}}", .{comment}) catch return error.OutOfMemory;

        const response = try self.request("POST", path, body);
        defer self.allocator.free(response);
    }

    pub fn deleteBranch(self: *Client, branch_name: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/git/refs/heads/{s}", .{
            self.owner,
            self.repo,
            branch_name,
        }) catch return error.OutOfMemory;

        const response = try self.request("DELETE", path, null);
        defer self.allocator.free(response);
    }

    fn request(self: *Client, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com{s}", .{path}) catch return error.OutOfMemory;

        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{self.token}) catch return error.OutOfMemory;

        var argv_buf: [16][]const u8 = undefined;
        var argc: usize = 0;

        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "-s";
        argc += 1;
        argv_buf[argc] = "-X";
        argc += 1;
        argv_buf[argc] = method;
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = auth_header;
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = "Accept: application/vnd.github+json";
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = "X-GitHub-Api-Version: 2022-11-28";
        argc += 1;

        if (body) |b| {
            argv_buf[argc] = "-d";
            argc += 1;
            argv_buf[argc] = b;
            argc += 1;
        }

        argv_buf[argc] = url;
        argc += 1;

        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch return error.RequestFailed;

        var stdout_list = std.ArrayListUnmanaged(u8){};
        var stderr_list = std.ArrayListUnmanaged(u8){};
        defer stderr_list.deinit(self.allocator);

        child.collectOutput(self.allocator, &stdout_list, &stderr_list, 10 * 1024 * 1024) catch {
            stdout_list.deinit(self.allocator);
            return error.RequestFailed;
        };

        const result = child.wait() catch {
            stdout_list.deinit(self.allocator);
            return error.RequestFailed;
        };

        if (result.Exited != 0) {
            stdout_list.deinit(self.allocator);
            return error.RequestFailed;
        }

        return stdout_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }
};
