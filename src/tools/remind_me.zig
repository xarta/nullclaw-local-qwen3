const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const loadScheduler = @import("cron_add.zig").loadScheduler;

/// remind_me tool — schedule a one-shot Telegram reminder.
///
/// Creates a one-shot cron (shell) job whose command sends a message via the
/// Telegram Bot API using curl.  The bot token and chat ID are read from the
/// TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID environment variables at job
/// run-time, so they never appear in source code or config files.
///
/// The message text is percent-encoded (RFC 3986) at schedule time so it can
/// be embedded safely in the URL regardless of its content (spaces, emoji,
/// punctuation, non-ASCII, etc.).
pub const RemindMeTool = struct {
    pub const tool_name = "remind_me";
    pub const tool_description =
        "Schedule a one-shot reminder that sends you a Telegram message after a delay. " ++
        "Parameters: 'message' (text to send) and 'delay' (e.g. '1m', '30m', '2h', '1d'). " ++
        "Returns the job ID — cancel a pending reminder with: schedule cancel <id>.";
    pub const tool_params =
        \\{"type":"object","properties":{"message":{"type":"string","minLength":1,"description":"Reminder text to send via Telegram"},"delay":{"type":"string","description":"How long until the reminder fires, e.g. '1m', '30m', '2h', '1d'"}},"required":["message","delay"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *RemindMeTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *RemindMeTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const message = root.getString(args, "message") orelse
            return ToolResult.fail("Missing required 'message' parameter");
        const delay = root.getString(args, "delay") orelse
            return ToolResult.fail("Missing required 'delay' parameter");

        if (message.len == 0)
            return ToolResult.fail("'message' must not be empty");

        // Validate delay before touching the scheduler.
        _ = cron.parseDuration(delay) catch
            return ToolResult.fail("Invalid 'delay': use e.g. '30m', '2h', '1d'");

        // Percent-encode the message so it is safe to embed in a URL query
        // string without any shell quoting concerns.
        const encoded = try percentEncode(allocator, message);
        defer allocator.free(encoded);

        // Build the curl command.  ${TELEGRAM_BOT_TOKEN} and ${TELEGRAM_CHAT_ID}
        // are expanded by the shell (/bin/sh -c) at job run-time using the
        // environment variables injected into the container via .env / compose.
        const command = try std.fmt.allocPrint(
            allocator,
            "curl -s -m 30 \"https://api.telegram.org/bot${{TELEGRAM_BOT_TOKEN}}/sendMessage?chat_id=${{TELEGRAM_CHAT_ID}}&text={s}\"",
            .{encoded},
        );
        defer allocator.free(command);

        var scheduler = loadScheduler(allocator) catch
            return ToolResult.fail("Failed to load scheduler state");
        defer scheduler.deinit();

        const job = scheduler.addOnce(delay, command) catch |err| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Failed to schedule reminder: {s}",
                .{@errorName(err)},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        cron.saveJobs(&scheduler) catch {};

        const out = try std.fmt.allocPrint(
            allocator,
            "Reminder set — job {s} fires in {s}. To cancel: schedule cancel {s}",
            .{ job.id, delay, job.id },
        );
        return ToolResult{ .success = true, .output = out };
    }

    /// Percent-encode a UTF-8 string for safe embedding in a URL query parameter
    /// value (RFC 3986 unreserved characters pass through; everything else →
    /// %XX uppercase hex).
    fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        // Worst case: each byte expands to 3 characters (%XX).
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.ensureTotalCapacity(allocator, input.len * 3);
        errdefer out.deinit(allocator);

        for (input) |byte| {
            if (isUnreserved(byte)) {
                try out.append(allocator, byte);
            } else {
                try out.appendSlice(allocator, &.{
                    '%',
                    hexNibble(byte >> 4),
                    hexNibble(byte & 0x0f),
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// RFC 3986 §2.3 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
    fn isUnreserved(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or
            c == '-' or c == '_' or c == '.' or c == '~';
    }

    fn hexNibble(n: u8) u8 {
        return if (n < 10) '0' + n else 'A' + (n - 10);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "remind_me tool name" {
    var rt = RemindMeTool{};
    const t = rt.tool();
    try std.testing.expectEqualStrings("remind_me", t.name());
}

test "remind_me schema has message and delay" {
    var rt = RemindMeTool{};
    const t = rt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "message") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delay") != null);
}

test "remind_me missing message" {
    var rt = RemindMeTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"delay\": \"30m\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "message") != null);
}

test "remind_me missing delay" {
    var rt = RemindMeTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"message\": \"hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "remind_me invalid delay" {
    var rt = RemindMeTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"message\": \"hello\", \"delay\": \"not-a-duration\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "remind_me empty message" {
    var rt = RemindMeTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"message\": \"\", \"delay\": \"1m\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "message") != null);
}

test "percentEncode plain text" {
    const result = try RemindMeTool.percentEncode(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello%20world", result);
}

test "percentEncode unreserved chars unchanged" {
    const input = "hello-world_test.case~end";
    const result = try RemindMeTool.percentEncode(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "percentEncode special chars" {
    // apostrophe → %27, exclamation → %21
    const result = try RemindMeTool.percentEncode(std.testing.allocator, "it's done!");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "%27") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "%21") != null);
}

test "percentEncode empty string" {
    const result = try RemindMeTool.percentEncode(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}
