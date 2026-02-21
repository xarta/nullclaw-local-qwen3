//! reflect — spawn a background thinking subagent to analyse a question in depth.
//!
//! The main agent often runs with `no_think: true` for low latency.  Reflect
//! lets it offload heavy reasoning to a background subagent that runs with
//! thinking enabled, without blocking the main conversation thread.
//!
//! Primary use-case: "background watcher" that analyses each user–assistant
//! exchange and surfaces things the assistant could have done better or
//! information it missed.  The vLLM server can handle these parallel requests
//! without impacting main-thread latency.
//!
//! Calling pattern:
//!   • The main agent calls `reflect` immediately after answering a user turn.
//!   • The subagent reasons in the background (thinking enabled).
//!   • Its result arrives as a system message; the next user turn can
//!     incorporate it or dismiss it silently.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const SubagentManager = @import("../subagent.zig").SubagentManager;

/// Default token budget for a reflect subagent.  Intentionally modest —
/// reflection should be targeted, not exhaustive.
const DEFAULT_REFLECT_TOKENS: u64 = 2048;

/// Maximum token budget the caller may request.
const MAX_REFLECT_TOKENS: u64 = 8192;

pub const ReflectTool = struct {
    manager: ?*SubagentManager = null,

    pub const tool_name = "reflect";
    pub const tool_description =
        "Spawn a thinking background subagent to analyse a question or conversation " ++
        "excerpt in depth. Thinking mode is always ON for reflect subagents, even " ++
        "when the main agent has no_think active. Use after answering a user turn to " ++
        "check for missed opportunities, implicit questions, or information the user " ++
        "was expecting. Results arrive as system messages.";
    pub const tool_params =
        \\{"type":"object","properties":{"question":{"type":"string","minLength":1,"description":"What to analyse — e.g. 'Did I miss anything the user was implying?'"},"context":{"type":"string","description":"Recent conversation excerpt to analyse (user message + assistant reply). Include enough context to judge quality."},"label":{"type":"string","description":"Human-readable label for this reflection task (default: reflect)"},"max_tokens":{"type":"integer","minimum":256,"maximum":8192,"description":"Token budget (default: 2048). Keep low — reasoning is concise by design."}},"required":["question"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ReflectTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ReflectTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const question = root.getString(args, "question") orelse
            return ToolResult.fail("Missing 'question' parameter");

        const trimmed_q = std.mem.trim(u8, question, " \t\n");
        if (trimmed_q.len == 0) {
            return ToolResult.fail("'question' must not be empty");
        }

        const context = root.getString(args, "context");
        const label = root.getString(args, "label") orelse "reflect";

        const max_tokens: u64 = blk: {
            if (root.getInt(args, "max_tokens")) |mt| {
                if (mt > 0) break :blk @min(@as(u64, @intCast(mt)), MAX_REFLECT_TOKENS);
            }
            break :blk DEFAULT_REFLECT_TOKENS;
        };

        const manager = self.manager orelse
            return ToolResult.fail("Reflect tool not connected to SubagentManager");

        // Build the reflection prompt.
        // The subagent system prompt (set in subagentThreadFn) primes it for
        // analysis.  We add a structured prefix so it focuses on the question.
        const task: []const u8 = if (context) |ctx|
            std.fmt.allocPrint(
                allocator,
                "[Reflection task]\nQuestion: {s}\n\nConversation context:\n{s}\n\n" ++
                    "Analyse the exchange above with the question in mind. " ++
                    "Be concise. If you find nothing worth flagging, say so briefly. " ++
                    "If you identify something useful, state it clearly so the main " ++
                    "agent can act on it in the next turn.",
                .{ trimmed_q, ctx },
            ) catch return ToolResult.fail("OOM building reflection task")
        else
            std.fmt.allocPrint(
                allocator,
                "[Reflection task]\nQuestion: {s}\n\n" ++
                    "Analyse this question carefully. " ++
                    "Be concise. State any useful conclusion clearly.",
                .{trimmed_q},
            ) catch return ToolResult.fail("OOM building reflection task");
        defer allocator.free(task);

        const channel = manager.current_channel;
        const chat_id = manager.current_chat_id;

        // Always spawn with thinking_override = true (force thinking mode).
        const task_id = manager.spawn(task, label, channel, chat_id, .{
            .thinking_override = true,
            .max_tokens = max_tokens,
        }) catch |err| {
            return switch (err) {
                error.TooManyConcurrentSubagents => ToolResult.fail(
                    "Too many concurrent subagents — reflection skipped. Try again after current tasks complete.",
                ),
                else => ToolResult.fail("Failed to spawn reflection subagent"),
            };
        };

        const msg = std.fmt.allocPrint(
            allocator,
            "Reflection subagent '{s}' spawned (task_id={d}, thinking=on, max_tokens={d}). " ++
                "Result will arrive as a system message.",
            .{ label, task_id, max_tokens },
        ) catch return ToolResult.ok("Reflection subagent spawned");

        return ToolResult.ok(msg);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "reflect tool name" {
    var rt = ReflectTool{};
    const t = rt.tool();
    try std.testing.expectEqualStrings("reflect", t.name());
}

test "reflect tool description mentions thinking" {
    var rt = ReflectTool{};
    const t = rt.tool();
    try std.testing.expect(std.mem.indexOf(u8, t.description(), "thinking") != null);
}

test "reflect tool schema has question and context" {
    var rt = ReflectTool{};
    const t = rt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "question") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "context") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "max_tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
}

test "reflect missing question rejected" {
    var rt = ReflectTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"context\": \"some text\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "question") != null);
}

test "reflect empty question rejected" {
    var rt = ReflectTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"question\": \"   \"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "empty") != null);
}

test "reflect without manager fails" {
    var rt = ReflectTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{\"question\": \"Did I miss anything?\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "SubagentManager") != null);
}

test "reflect empty JSON rejected" {
    var rt = ReflectTool{};
    const t = rt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "reflect DEFAULT_REFLECT_TOKENS constant" {
    try std.testing.expectEqual(@as(u64, 2048), DEFAULT_REFLECT_TOKENS);
}

test "reflect MAX_REFLECT_TOKENS constant" {
    try std.testing.expectEqual(@as(u64, 8192), MAX_REFLECT_TOKENS);
}
