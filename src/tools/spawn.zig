const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const SubagentManager = @import("../subagent.zig").SubagentManager;

/// Spawn tool — launches a background subagent to work on a task asynchronously.
/// Returns a task ID immediately. Results are delivered as system messages.
pub const SpawnTool = struct {
    manager: ?*SubagentManager = null,

    pub const tool_name = "spawn";
    pub const tool_description = "Spawn a background subagent to work on a task asynchronously. Returns a task ID immediately. Results are delivered as system messages when complete. Use `thinking: true` to enable chain-of-thought reasoning for complex tasks, even when the main agent has no_think mode active.";
    pub const tool_params =
        \\{"type":"object","properties":{"task":{"type":"string","minLength":1,"description":"The task/prompt for the subagent"},"label":{"type":"string","description":"Optional human-readable label for tracking"},"thinking":{"type":"boolean","description":"Enable chain-of-thought reasoning for this subagent (overrides global no_think). Use for complex analytical tasks."},"max_tokens":{"type":"integer","minimum":256,"maximum":8192,"description":"Token budget for the subagent response (default: 4096)"}},"required":["task"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SpawnTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SpawnTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task = root.getString(args, "task") orelse
            return ToolResult.fail("Missing 'task' parameter");

        const trimmed_task = std.mem.trim(u8, task, " \t\n");
        if (trimmed_task.len == 0) {
            return ToolResult.fail("'task' must not be empty");
        }

        const label = root.getString(args, "label") orelse "subagent";

        const manager = self.manager orelse
            return ToolResult.fail("Spawn tool not connected to SubagentManager");

        const channel = manager.current_channel;
        const chat_id = manager.current_chat_id;

        const task_id = manager.spawn(trimmed_task, label, channel, chat_id, .{
            .thinking_override = root.getBool(args, "thinking"),
            .max_tokens = blk: {
                if (root.getInt(args, "max_tokens")) |mt| {
                    if (mt > 0) break :blk @intCast(mt);
                }
                break :blk null;
            },
        }) catch |err| {
            return switch (err) {
                error.TooManyConcurrentSubagents => ToolResult.fail("Too many concurrent subagents. Wait for some to complete."),
                else => ToolResult.fail("Failed to spawn subagent"),
            };
        };

        const msg = std.fmt.allocPrint(
            allocator,
            "Subagent '{s}' spawned with task_id={d}. Results will be delivered as system messages.",
            .{ label, task_id },
        ) catch return ToolResult.ok("Subagent spawned");

        return ToolResult.ok(msg);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "spawn tool name" {
    var st = SpawnTool{};
    const t = st.tool();
    try std.testing.expectEqualStrings("spawn", t.name());
}

test "spawn tool description" {
    var st = SpawnTool{};
    const t = st.tool();
    try std.testing.expect(t.description().len > 0);
}

test "spawn tool schema has task" {
    var st = SpawnTool{};
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "task") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "label") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "max_tokens") != null);
}

test "spawn tool description mentions thinking" {
    var st = SpawnTool{};
    const t = st.tool();
    try std.testing.expect(std.mem.indexOf(u8, t.description(), "thinking") != null);
}

test "spawn missing task parameter" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"label\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "task") != null);
}

test "spawn empty task rejected" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"task\": \"  \"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "empty") != null);
}

test "spawn without manager fails" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"task\": \"do something\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "SubagentManager") != null);
}

test "spawn empty JSON rejected" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}
