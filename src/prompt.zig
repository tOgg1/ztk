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
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var writer = result.writer();

    // Replace template variables
    var i: usize = 0;
    while (i < default_template.len) {
        if (default_template[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, default_template, i, '}') orelse break;
            const key = default_template[i + 1 .. end];
            const value = getValue(key, comment, context);
            try writer.writeAll(value);
            i = end + 1;
        } else {
            try writer.writeByte(default_template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
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
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var writer = result.writer();

    try writer.writeAll("# Code Review Feedback\n\n");

    // Context section
    try writer.writeAll("## Context\n");
    try std.fmt.format(writer, "- **Pull Request**: {s} (#{d})\n", .{ context.pr_title, context.pr_number });
    try std.fmt.format(writer, "- **Branch**: {s}\n", .{context.branch});

    if (comment.path) |path| {
        if (comment.line) |line| {
            try std.fmt.format(writer, "- **File**: {s}:{d}\n", .{ path, line });
        } else {
            try std.fmt.format(writer, "- **File**: {s}\n", .{path});
        }
    }
    try std.fmt.format(writer, "- **Reviewer**: {s}\n", .{comment.author});
    try writer.writeAll("\n");

    // Feedback section
    try writer.writeAll("## Feedback\n");
    try writer.writeAll(comment.body);
    try writer.writeAll("\n\n");

    // Code context section
    if (comment.diff_hunk) |diff| {
        try writer.writeAll("## Code Context\n```diff\n");
        try writer.writeAll(diff);
        try writer.writeAll("\n```\n\n");
    }

    // Instructions
    try writer.writeAll("## Instructions\n");
    try writer.writeAll("Please address this code review feedback:\n");
    try writer.writeAll("1. Analyze the reviewer's concern\n");
    try writer.writeAll("2. Explain your approach to resolving it\n");
    try writer.writeAll("3. Provide the corrected code\n");

    return result.toOwnedSlice();
}

/// Format a review summary (approval/changes requested) with LLM context
pub fn formatReview(
    allocator: std.mem.Allocator,
    r: review.Review,
    context: PromptContext,
) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var writer = result.writer();

    try writer.writeAll("# Code Review Summary\n\n");

    // Context section
    try writer.writeAll("## Context\n");
    try std.fmt.format(writer, "- **Pull Request**: {s} (#{d})\n", .{ context.pr_title, context.pr_number });
    try std.fmt.format(writer, "- **Branch**: {s}\n", .{context.branch});
    try std.fmt.format(writer, "- **Reviewer**: {s}\n", .{r.author});
    try std.fmt.format(writer, "- **Status**: {s}\n", .{r.state.toString()});
    try writer.writeAll("\n");

    // Review body
    if (r.body) |body| {
        try writer.writeAll("## Review Comments\n");
        try writer.writeAll(body);
        try writer.writeAll("\n\n");
    }

    // Instructions based on state
    try writer.writeAll("## Instructions\n");
    switch (r.state) {
        .changes_requested => {
            try writer.writeAll("The reviewer has requested changes. Please:\n");
            try writer.writeAll("1. Review their feedback carefully\n");
            try writer.writeAll("2. Address each concern mentioned\n");
            try writer.writeAll("3. Explain how you've resolved the issues\n");
        },
        .approved => {
            try writer.writeAll("The review has been approved. No action needed.\n");
        },
        .commented => {
            try writer.writeAll("The reviewer left comments. Please:\n");
            try writer.writeAll("1. Review their feedback\n");
            try writer.writeAll("2. Address any questions or suggestions\n");
        },
        else => {
            try writer.writeAll("Please review and address any feedback.\n");
        },
    }

    return result.toOwnedSlice();
}
