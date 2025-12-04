const std = @import("std");

pub const ReviewState = enum {
    approved,
    changes_requested,
    commented,
    dismissed,
    pending,

    pub fn fromString(s: []const u8) ?ReviewState {
        if (std.mem.eql(u8, s, "APPROVED")) return .approved;
        if (std.mem.eql(u8, s, "CHANGES_REQUESTED")) return .changes_requested;
        if (std.mem.eql(u8, s, "COMMENTED")) return .commented;
        if (std.mem.eql(u8, s, "DISMISSED")) return .dismissed;
        if (std.mem.eql(u8, s, "PENDING")) return .pending;
        return null;
    }

    pub fn toString(self: ReviewState) []const u8 {
        return switch (self) {
            .approved => "approved",
            .changes_requested => "changes_requested",
            .commented => "commented",
            .dismissed => "dismissed",
            .pending => "pending",
        };
    }
};

pub const ReviewComment = struct {
    id: u64,
    body: []const u8,
    path: ?[]const u8, // file path (null for general comments)
    line: ?u32, // line number
    original_line: ?u32, // original line in the diff
    diff_hunk: ?[]const u8, // surrounding diff context
    author: []const u8,
    created_at: []const u8,
    in_reply_to_id: ?u64, // for threading

    pub fn deinit(self: *ReviewComment, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.path) |p| allocator.free(p);
        if (self.diff_hunk) |d| allocator.free(d);
        allocator.free(self.author);
        allocator.free(self.created_at);
    }
};

pub const Review = struct {
    id: u64,
    state: ReviewState,
    body: ?[]const u8, // review summary
    author: []const u8,
    submitted_at: []const u8,

    pub fn deinit(self: *Review, allocator: std.mem.Allocator) void {
        if (self.body) |b| allocator.free(b);
        allocator.free(self.author);
        allocator.free(self.submitted_at);
    }
};

pub const PRReviewSummary = struct {
    pr_number: u32,
    pr_title: []const u8,
    pr_url: []const u8,
    branch: []const u8,
    reviews: []Review,
    comments: []ReviewComment,

    pub fn deinit(self: *PRReviewSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.pr_title);
        allocator.free(self.pr_url);
        allocator.free(self.branch);

        for (self.reviews) |*r| {
            var review = r;
            review.deinit(allocator);
        }
        allocator.free(self.reviews);

        for (self.comments) |*c| {
            var comment = c;
            comment.deinit(allocator);
        }
        allocator.free(self.comments);
    }

    /// Get total count of actionable feedback items
    pub fn feedbackCount(self: *const PRReviewSummary) usize {
        var count: usize = 0;

        // Count review summaries with bodies
        for (self.reviews) |r| {
            if (r.body != null and r.state != .pending) {
                count += 1;
            }
        }

        // Count inline comments
        count += self.comments.len;

        return count;
    }
};
