const std = @import("std");
const config = @import("config.zig");

pub const PRStatus = struct {
    checks_passed: bool,
    approved: bool,
    mergeable: bool,
};

pub const PullRequest = struct {
    number: u32,
    html_url: []const u8,
    state: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
    title: []const u8,
    mergeable: bool,

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
    token_owned: bool,
    owner: []const u8,
    repo: []const u8,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) GitHubError!Client {
        if (std.posix.getenv("GITHUB_TOKEN")) |env_token| {
            return Client{
                .allocator = allocator,
                .token = env_token,
                .token_owned = false,
                .owner = cfg.owner,
                .repo = cfg.repo,
            };
        }

        const gh_token = getGhToken(allocator) catch {
            return GitHubError.NoToken;
        };

        return Client{
            .allocator = allocator,
            .token = gh_token,
            .token_owned = true,
            .owner = cfg.owner,
            .repo = cfg.repo,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.token_owned) {
            self.allocator.free(self.token);
        }
    }

    fn getGhToken(allocator: std.mem.Allocator) ![]const u8 {
        var child = std.process.Child.init(&.{ "gh", "auth", "token" }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch return error.NoToken;

        var stdout_list = std.ArrayListUnmanaged(u8){};
        var stderr_list = std.ArrayListUnmanaged(u8){};
        defer stderr_list.deinit(allocator);

        child.collectOutput(allocator, &stdout_list, &stderr_list, 1024) catch {
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

        const raw_token = stdout_list.toOwnedSlice(allocator) catch return error.NoToken;
        const trimmed = std.mem.trim(u8, raw_token, "\n\r ");
        
        if (trimmed.ptr == raw_token.ptr and trimmed.len == raw_token.len) {
            return raw_token;
        }
        
        const token = allocator.dupe(u8, trimmed) catch {
            allocator.free(raw_token);
            return error.NoToken;
        };
        allocator.free(raw_token);
        return token;
    }

    pub fn findPR(self: *Client, head_branch: []const u8) GitHubError!?PullRequest {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls?head={s}:{s}&state=open", .{
            self.owner,
            self.repo,
            self.owner,
            head_branch,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("GET", url, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .array) return null;

        const array = parsed.value.array;
        if (array.items.len == 0) return null;

        const pr = array.items[0].object;
        const parsed_pr = self.parsePR(pr) catch |err| return err;
        return parsed_pr;
    }

    pub fn createPR(self: *Client, head: []const u8, base: []const u8, title: []const u8, body: []const u8) GitHubError!PullRequest {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls", .{
            self.owner,
            self.repo,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [8192]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf, "{{\"title\":\"{s}\",\"body\":\"{s}\",\"head\":\"{s}\",\"base\":\"{s}\"}}", .{
            escapeJson(title),
            escapeJson(body),
            head,
            base,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("POST", url, json_body) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return GitHubError.ParseError;
        }

        const obj = parsed.value.object;
        if (obj.get("number") == null) {
            if (obj.get("message")) |msg| {
                std.debug.print("GitHub API error: {s}\n", .{msg.string});
            }
            return GitHubError.RequestFailed;
        }

        return self.parsePR(obj);
    }

    pub fn updatePR(self: *Client, pr_number: u32, title: ?[]const u8, body: ?[]const u8, base: ?[]const u8) GitHubError!void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&json_buf);
        const writer = fbs.writer();

        writer.writeAll("{") catch return GitHubError.OutOfMemory;
        var first = true;

        if (title) |t| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.print("\"title\":\"{s}\"", .{escapeJson(t)}) catch return GitHubError.OutOfMemory;
            first = false;
        }
        if (body) |b| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.print("\"body\":\"{s}\"", .{escapeJson(b)}) catch return GitHubError.OutOfMemory;
            first = false;
        }
        if (base) |bs| {
            if (!first) writer.writeAll(",") catch return GitHubError.OutOfMemory;
            writer.print("\"base\":\"{s}\"", .{bs}) catch return GitHubError.OutOfMemory;
            first = false;
        }

        writer.writeAll("}") catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("PATCH", url, fbs.getWritten()) catch return GitHubError.RequestFailed;
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

    pub fn getPR(self: *Client, pr_number: u32) GitHubError!PullRequest {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("GET", url, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return GitHubError.ParseError;
        }

        return self.parsePR(parsed.value.object);
    }

    pub fn getPRStatus(self: *Client, pr_number: u32) GitHubError!PRStatus {
        const pr = try self.getPR(pr_number);
        defer {
            var mutable_pr = pr;
            mutable_pr.deinit(self.allocator);
        }

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls/{d}/reviews", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("GET", url, null) catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        var approved = false;
        if (parsed.value == .array) {
            for (parsed.value.array.items) |review| {
                if (review == .object) {
                    if (review.object.get("state")) |state| {
                        if (state == .string and std.mem.eql(u8, state.string, "APPROVED")) {
                            approved = true;
                            break;
                        }
                    }
                }
            }
        }

        return PRStatus{
            .checks_passed = true,
            .approved = approved,
            .mergeable = pr.mergeable,
        };
    }

    pub fn mergePR(self: *Client, pr_number: u32) GitHubError!void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls/{d}/merge", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("PUT", url, "{\"merge_method\":\"squash\"}") catch return GitHubError.RequestFailed;
        defer self.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
            return GitHubError.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("merged")) |merged| {
                if (merged == .bool and merged.bool) {
                    return;
                }
            }
            if (parsed.value.object.get("message")) |msg| {
                if (msg == .string) {
                    std.debug.print("Merge failed: {s}\n", .{msg.string});
                }
            }
        }

        return GitHubError.RequestFailed;
    }

    pub fn closePR(self: *Client, pr_number: u32) GitHubError!void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/pulls/{d}", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("PATCH", url, "{\"state\":\"closed\"}") catch return GitHubError.RequestFailed;
        self.allocator.free(response);
    }

    pub fn commentPR(self: *Client, pr_number: u32, comment: []const u8) GitHubError!void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/issues/{d}/comments", .{
            self.owner,
            self.repo,
            pr_number,
        }) catch return GitHubError.OutOfMemory;

        var json_buf: [4096]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf, "{{\"body\":\"{s}\"}}", .{
            escapeJson(comment),
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("POST", url, json_body) catch return GitHubError.RequestFailed;
        self.allocator.free(response);
    }

    pub fn deleteBranch(self: *Client, branch: []const u8) GitHubError!void {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/git/refs/heads/{s}", .{
            self.owner,
            self.repo,
            branch,
        }) catch return GitHubError.OutOfMemory;

        const response = self.curlRequest("DELETE", url, null) catch return GitHubError.RequestFailed;
        self.allocator.free(response);
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

        const pr_title = self.allocator.dupe(u8, obj.get("title").?.string) catch return GitHubError.OutOfMemory;

        const mergeable = if (obj.get("mergeable")) |m| (m == .bool and m.bool) else false;

        return PullRequest{
            .number = number,
            .html_url = html_url,
            .state = state,
            .head_ref = head_ref,
            .base_ref = base_ref,
            .title = pr_title,
            .mergeable = mergeable,
        };
    }

    fn curlRequest(self: *Client, method: []const u8, url: []const u8, body: ?[]const u8) ![]u8 {
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

        if (body != null) {
            argv_buf[argc] = "-H";
            argc += 1;
            argv_buf[argc] = "Content-Type: application/json";
            argc += 1;
            argv_buf[argc] = "-d";
            argc += 1;
            argv_buf[argc] = body.?;
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

fn escapeJson(s: []const u8) []const u8 {
    return s;
}
