const std = @import("std");
const review = @import("review.zig");

pub const PromptContext = struct {
    pr_title: []const u8,
    pr_number: u32,
    branch: []const u8,
};

/// Default LLM prompt template for code review feedback
pub const default_template =
    \\# Code Review Feedback
    \\
    \\## Context
    \\- **Pull Request**: {pr_title} (#{pr_number})
    \\- **Branch**: {branch}
    \\- **File**: {file_path}:{line}
    \\- **Reviewer**: {author}
    \\
    \\## Feedback
    \\{comment_body}
    \\
    \\## Code Context
    \\```diff
    \\{diff_hunk}
    \\```
    \\
    \\## Instructions
    \\Please address this code review feedback:
    \\1. Analyze the reviewer's concern
    \\2. Explain your approach to resolving it
    \\3. Provide the corrected code
    \\
;

/// Format a review comment with LLM prompt template
pub fn formatComment(
    allocator: std.mem.Allocator,
    comment: review.ReviewComment,
    context: PromptContext,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    // Replace template variables
    var i: usize = 0;
    while (i < default_template.len) {
        if (default_template[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, default_template, i, '}') orelse break;
            const key = default_template[i + 1 .. end];
            const value = getValue(key, comment, context);
            try result.appendSlice(allocator, value);
            i = end + 1;
        } else {
            try result.append(allocator, default_template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn getValue(key: []const u8, comment: review.ReviewComment, context: PromptContext) []const u8 {
    if (std.mem.eql(u8, key, "pr_title")) {
        return context.pr_title;
    } else if (std.mem.eql(u8, key, "pr_number")) {
        // Return as static string for common numbers, otherwise placeholder
        return "[PR]";
    } else if (std.mem.eql(u8, key, "branch")) {
        return context.branch;
    } else if (std.mem.eql(u8, key, "file_path")) {
        return comment.path orelse "(general)";
    } else if (std.mem.eql(u8, key, "line")) {
        return "[line]"; // Would need formatting buffer
    } else if (std.mem.eql(u8, key, "author")) {
        return comment.author;
    } else if (std.mem.eql(u8, key, "comment_body")) {
        return comment.body;
    } else if (std.mem.eql(u8, key, "diff_hunk")) {
        return comment.diff_hunk orelse "(no diff context)";
    }
    return "";
}

/// Format a review comment with full context for LLM
pub fn formatCommentFull(
    allocator: std.mem.Allocator,
    comment: review.ReviewComment,
    context: PromptContext,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "# Code Review Feedback\n\n");

    // Context section
    try result.appendSlice(allocator, "## Context\n");

    // Build formatted strings using writer for safe formatting
    try result.writer(allocator).print("- **Pull Request**: {s} (#{d})\n", .{ context.pr_title, context.pr_number });
    try result.writer(allocator).print("- **Branch**: {s}\n", .{context.branch});

    if (comment.path) |path| {
        if (comment.line) |line| {
            try result.writer(allocator).print("- **File**: {s}:{d}\n", .{ path, line });
        } else {
            try result.writer(allocator).print("- **File**: {s}\n", .{path});
        }
    }
    try result.writer(allocator).print("- **Reviewer**: {s}\n", .{comment.author});
    try result.appendSlice(allocator, "\n");

    // Feedback section
    try result.appendSlice(allocator, "## Feedback\n");
    try result.appendSlice(allocator, comment.body);
    try result.appendSlice(allocator, "\n\n");

    // Code context section
    if (comment.diff_hunk) |diff| {
        try result.appendSlice(allocator, "## Code Context\n```diff\n");
        try result.appendSlice(allocator, diff);
        try result.appendSlice(allocator, "\n```\n\n");
    }

    // Instructions
    try result.appendSlice(allocator, "## Instructions\n");
    try result.appendSlice(allocator, "Please address this code review feedback:\n");
    try result.appendSlice(allocator, "1. Analyze the reviewer's concern\n");
    try result.appendSlice(allocator, "2. Explain your approach to resolving it\n");
    try result.appendSlice(allocator, "3. Provide the corrected code\n");

    return result.toOwnedSlice(allocator);
}

/// Format a review summary (approval/changes requested) with LLM context
pub fn formatReview(
    allocator: std.mem.Allocator,
    r: review.Review,
    context: PromptContext,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "# Code Review Summary\n\n");

    // Context section
    try result.appendSlice(allocator, "## Context\n");

    // Build formatted strings using writer for safe formatting
    try result.writer(allocator).print("- **Pull Request**: {s} (#{d})\n", .{ context.pr_title, context.pr_number });
    try result.writer(allocator).print("- **Branch**: {s}\n", .{context.branch});
    try result.writer(allocator).print("- **Reviewer**: {s}\n", .{r.author});
    try result.writer(allocator).print("- **Status**: {s}\n", .{r.state.toString()});

    try result.appendSlice(allocator, "\n");

    // Review body
    if (r.body) |body| {
        try result.appendSlice(allocator, "## Review Comments\n");
        try result.appendSlice(allocator, body);
        try result.appendSlice(allocator, "\n\n");
    }

    // Instructions based on state
    try result.appendSlice(allocator, "## Instructions\n");
    switch (r.state) {
        .changes_requested => {
            try result.appendSlice(allocator, "The reviewer has requested changes. Please:\n");
            try result.appendSlice(allocator, "1. Review their feedback carefully\n");
            try result.appendSlice(allocator, "2. Address each concern mentioned\n");
            try result.appendSlice(allocator, "3. Explain how you've resolved the issues\n");
        },
        .approved => {
            try result.appendSlice(allocator, "The review has been approved. No action needed.\n");
        },
        .commented => {
            try result.appendSlice(allocator, "The reviewer left comments. Please:\n");
            try result.appendSlice(allocator, "1. Review their feedback\n");
            try result.appendSlice(allocator, "2. Address any questions or suggestions\n");
        },
        else => {
            try result.appendSlice(allocator, "Please review and address any feedback.\n");
        },
    }

    return result.toOwnedSlice(allocator);
}
