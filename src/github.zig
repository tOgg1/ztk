const std = @import("std");
const config = @import("config.zig");
const review = @import("review.zig");

pub const PullRequest = struct {
    number: u32,
    html_url: []const u8,
    state: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
    title: []const u8,

    pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.html_url);
        allocator.free(self.state);
        allocator.free(self.head_ref);
        allocator.free(self.base_ref);
        allocator.free(self.title);
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

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) GitHubError!Client {
        const token = std.posix.getenv("GITHUB_TOKEN") orelse {
            return GitHubError.NoToken;
        };

        return Client{
            .allocator = allocator,
            .token = token,
            .owner = cfg.owner,
            .repo = cfg.repo,
        };
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

        const array = parsed.value.array;
        if (array.items.len == 0) return null;

        const pr_obj = array.items[0].object;
        return try self.parsePR(pr_obj);
    }

    pub fn createPR(self: *Client, head: []const u8, base: []const u8, title: []const u8, body: []const u8) GitHubError!PullRequest {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls", .{
            self.owner,
            self.repo,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&json_buf);
        std.json.stringify(.{
            .title = title,
            .body = body,
            .head = head,
            .base = base,
        }, .{}, fbs.writer()) catch return GitHubError.OutOfMemory;

        const response = self.request("POST", path, fbs.getWritten()) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        return self.parsePR(parsed.value.object);
    }

    pub fn updatePR(self: *Client, pr_number: u32, title: ?[]const u8, body: ?[]const u8, base: ?[]const u8) GitHubError!void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&json_buf);
        var writer = fbs.writer();

        writer.writeAll("{") catch return GitHubError.OutOfMemory;
        var first = true;

        if (title) |t| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.print("\"title\":", .{}) catch return GitHubError.OutOfMemory;
            std.json.stringify(t, .{}, writer) catch return GitHubError.OutOfMemory;
            first = false;
        }
        if (body) |b| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.print("\"body\":", .{}) catch return GitHubError.OutOfMemory;
            std.json.stringify(b, .{}, writer) catch return GitHubError.OutOfMemory;
            first = false;
        }
        if (base) |bs| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.print("\"base\":", .{}) catch return GitHubError.OutOfMemory;
            std.json.stringify(bs, .{}, writer) catch return GitHubError.OutOfMemory;
            first = false;
        }

        writer.writeAll("}") catch return GitHubError.OutOfMemory;

        const response = self.request("PATCH", path, fbs.getWritten()) catch return GitHubError.RequestFailed;
        self.allocator.free(response);
    }

    pub fn createOrUpdatePR(self: *Client, head: []const u8, base: []const u8, title: []const u8, body: []const u8) GitHubError!PullRequest {
        if (try self.findPR(head)) |existing| {
            const pr = existing;
            try self.updatePR(pr.number, title, body, base);
            return pr;
        }
        return try self.createPR(head, base, title, body);
    }

    /// Fetch all reviews for a PR
    /// GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews
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
    /// GET /repos/{owner}/{repo}/pulls/{pull_number}/comments
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

        const base_obj = obj.get("base").?.object;
        const base_ref = self.allocator.dupe(u8, base_obj.get("ref").?.string) catch return GitHubError.OutOfMemory;
        errdefer self.allocator.free(base_ref);

        const title = self.allocator.dupe(u8, obj.get("title").?.string) catch return GitHubError.OutOfMemory;

        return PullRequest{
            .number = number,
            .html_url = html_url,
            .state = state,
            .head_ref = head_ref,
            .base_ref = base_ref,
            .title = title,
        };
    }

    fn request(self: *Client, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var uri_buf: [1024]u8 = undefined;
        const uri_str = std.fmt.bufPrint(&uri_buf, "https://api.github.com{s}", .{path}) catch return error.OutOfMemory;

        const uri = std.Uri.parse(uri_str) catch return error.InvalidUri;

        const method_enum: std.http.Method = if (std.mem.eql(u8, method, "GET"))
            .GET
        else if (std.mem.eql(u8, method, "POST"))
            .POST
        else if (std.mem.eql(u8, method, "PATCH"))
            .PATCH
        else if (std.mem.eql(u8, method, "DELETE"))
            .DELETE
        else
            .GET;

        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.token}) catch return error.OutOfMemory;

        var response_storage: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer self.allocator.free(response_storage.writer.buffer);

        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = method_enum,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Accept", .value = "application/vnd.github+json" },
                .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
                .{ .name = "User-Agent", .value = "ztk" },
            },
            .payload = body,
            .response_writer = &response_storage.writer,
        }) catch return error.RequestFailed;

        if (result.status != .ok and result.status != .created) {
            self.allocator.free(response_storage.writer.buffer);
            return error.RequestFailed;
        }

        // Return the response data as an owned slice
        const response_data = response_storage.writer.buffer[0..response_storage.writer.end];
        const result_slice = self.allocator.dupe(u8, response_data) catch return error.OutOfMemory;
        self.allocator.free(response_storage.writer.buffer);
        return result_slice;
    }
};
