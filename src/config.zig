const std = @import("std");
const ui = @import("ui.zig");

pub const Config = struct {
    owner: []const u8,
    repo: []const u8,
    main_branch: []const u8,
    remote: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.main_branch);
        allocator.free(self.remote);
    }
};

pub const ConfigError = error{
    NotInGitRepo,
    ConfigNotFound,
    InvalidConfig,
    OutOfMemory,
    FileError,
};

const config_filename = ".ztk.json";

pub fn findRepoRoot(allocator: std.mem.Allocator) ConfigError![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const initial_path = std.fs.cwd().realpathZ(".", &path_buf) catch {
        return ConfigError.NotInGitRepo;
    };

    var current_path = allocator.dupe(u8, initial_path) catch return ConfigError.OutOfMemory;
    defer allocator.free(current_path);

    while (true) {
        var dir = std.fs.openDirAbsolute(current_path, .{}) catch {
            return ConfigError.NotInGitRepo;
        };
        defer dir.close();

        dir.access(".git", .{}) catch {
            const parent = std.fs.path.dirname(current_path);
            if (parent) |p| {
                const new_path = allocator.dupe(u8, p) catch return ConfigError.OutOfMemory;
                allocator.free(current_path);
                current_path = new_path;
                continue;
            }
            return ConfigError.NotInGitRepo;
        };

        return allocator.dupe(u8, current_path) catch return ConfigError.OutOfMemory;
    }
}

pub fn load(allocator: std.mem.Allocator) ConfigError!Config {
    const repo_root = try findRepoRoot(allocator);
    defer allocator.free(repo_root);

    const config_path = std.fs.path.join(allocator, &.{ repo_root, config_filename }) catch {
        return ConfigError.OutOfMemory;
    };
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        return ConfigError.ConfigNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return ConfigError.FileError;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return ConfigError.InvalidConfig;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    const owner = allocator.dupe(u8, root.get("owner").?.string) catch return ConfigError.OutOfMemory;
    errdefer allocator.free(owner);

    const repo = allocator.dupe(u8, root.get("repo").?.string) catch return ConfigError.OutOfMemory;
    errdefer allocator.free(repo);

    const main_branch_val = root.get("main_branch") orelse root.get("mainBranch") orelse {
        return ConfigError.InvalidConfig;
    };
    const main_branch = allocator.dupe(u8, main_branch_val.string) catch return ConfigError.OutOfMemory;
    errdefer allocator.free(main_branch);

    const remote_val = root.get("remote");
    const remote = if (remote_val) |v|
        allocator.dupe(u8, v.string) catch return ConfigError.OutOfMemory
    else
        allocator.dupe(u8, "origin") catch return ConfigError.OutOfMemory;

    return Config{
        .owner = owner,
        .repo = repo,
        .main_branch = main_branch,
        .remote = remote,
    };
}

pub fn initDefault(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ConfigError!void {
    const repo_root = try findRepoRoot(allocator);
    defer allocator.free(repo_root);

    const config_path = std.fs.path.join(allocator, &.{ repo_root, config_filename }) catch {
        return ConfigError.OutOfMemory;
    };
    defer allocator.free(config_path);

    const file = std.fs.createFileAbsolute(config_path, .{}) catch {
        return ConfigError.FileError;
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, "{{\n  \"owner\": \"{s}\",\n  \"repo\": \"{s}\",\n  \"main_branch\": \"main\",\n  \"remote\": \"origin\"\n}}\n", .{ owner, repo }) catch {
        return ConfigError.FileError;
    };
    file.writeAll(output) catch {
        return ConfigError.FileError;
    };
}

pub fn configExists(allocator: std.mem.Allocator) bool {
    const repo_root = findRepoRoot(allocator) catch return false;
    defer allocator.free(repo_root);

    const config_path = std.fs.path.join(allocator, &.{ repo_root, config_filename }) catch return false;
    defer allocator.free(config_path);

    std.fs.accessAbsolute(config_path, .{}) catch return false;
    return true;
}
