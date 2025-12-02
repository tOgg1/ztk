const std = @import("std");
const config = @import("config.zig");

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

        const pr = array.items[0].object;
        return self.parsePR(pr);
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
            var pr = existing;
            try self.updatePR(pr.number, title, body, base);
            return pr;
        }
        return try self.createPR(head, base, title, body);
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

        var header_buf: [4096]u8 = undefined;
        var req = client.open(method_enum, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Accept", .value = "application/vnd.github+json" },
                .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
                .{ .name = "User-Agent", .value = "ztk" },
            },
        }) catch return error.RequestFailed;
        defer req.deinit();

        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
        }

        req.send() catch return error.RequestFailed;

        if (body) |b| {
            req.writer().writeAll(b) catch return error.RequestFailed;
        }

        req.finish() catch return error.RequestFailed;
        req.wait() catch return error.RequestFailed;

        const response = req.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch return error.OutOfMemory;
        return response;
    }
};
