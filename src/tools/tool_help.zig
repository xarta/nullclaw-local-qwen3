const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// tool_help — man-page-style reference for complex tools.
///
/// This tool lets the model fetch extended parameter documentation, usage
/// examples, and gotchas for any tool that has opted in by declaring a
/// `pub const tool_help: []const u8` constant.
///
/// Tools that have NOT opted in return a short message saying the schema
/// they already have in context is sufficient.
///
/// The `tools` slice is set by `allTools()` after construction — see the
/// initialisation pattern there.  The tool deliberately excludes itself
/// from its own tools slice; calling tool_help("tool_help") returns the
/// default no-extended-help message.
///
/// Usage guidance belongs in AGENTS.md — list the specific tool names that
/// are worth calling tool_help for.  The model should NOT call this for
/// every tool, only when genuinely uncertain.
pub const ToolHelpTool = struct {
    /// Slice of all tools in this agent's tool set.
    /// Set by allTools() after construction — starts as empty.
    tools: []const Tool,

    pub const tool_name = "tool_help";
    pub const tool_description =
        "Get extended help (parameters, examples, gotchas) for a specific tool by name. " ++
        "Use when uncertain about a tool's parameters or expected behaviour. " ++
        "Not all tools have extended help — basic tools will tell you to use the schema you already have.";
    pub const tool_params =
        \\{"type":"object","properties":{"tool_name":{"type":"string","description":"Name of the tool to get extended help for, e.g. \"remind_me\""}},"required":["tool_name"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ToolHelpTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ToolHelpTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const name_arg = root.getString(args, "tool_name") orelse
            return ToolResult.fail("Missing required 'tool_name' parameter");

        if (name_arg.len == 0)
            return ToolResult.fail("'tool_name' must not be empty");

        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name(), name_arg)) {
                return ToolResult.ok(t.help());
            }
        }

        // Tool name not found — return a helpful error
        const msg = try std.fmt.allocPrint(
            allocator,
            "Unknown tool: '{s}'. Check the tool list in your context for valid names.",
            .{name_arg},
        );
        return .{ .success = false, .output = "", .error_msg = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "tool_help tool name and description" {
    var th = ToolHelpTool{ .tools = &.{} };
    const t = th.tool();
    try std.testing.expectEqualStrings("tool_help", t.name());
    try std.testing.expect(t.description().len > 0);
}

test "tool_help unknown tool returns error" {
    var th = ToolHelpTool{ .tools = &.{} };
    const t = th.tool();
    const parsed = try root.parseTestArgs("{\"tool_name\":\"nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "tool_help missing param returns error" {
    var th = ToolHelpTool{ .tools = &.{} };
    const t = th.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "tool_help dispatches to help() on matching tool" {
    // Build a minimal stub tool with a known help text to verify dispatch
    const StubTool = struct {
        pub const tool_name = "stub";
        pub const tool_description = "stub";
        pub const tool_params = "{}";
        pub const tool_help = "Extended help for stub.";
        const vt = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vt };
        }
        pub fn execute(_: *@This(), _: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
            return ToolResult.ok("");
        }
    };

    var stub = StubTool{};
    const stub_tool = stub.tool();

    var th = ToolHelpTool{ .tools = &.{stub_tool} };
    const t = th.tool();

    const parsed = try root.parseTestArgs("{\"tool_name\":\"stub\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Extended help for stub.", result.output);
}

test "tool_help fallback for tool without tool_help const" {
    const BasicTool = struct {
        pub const tool_name = "basic";
        pub const tool_description = "basic";
        pub const tool_params = "{}";
        // No tool_help — should get default message
        const vt = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vt };
        }
        pub fn execute(_: *@This(), _: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
            return ToolResult.ok("");
        }
    };

    var basic = BasicTool{};
    const basic_tool = basic.tool();

    var th = ToolHelpTool{ .tools = &.{basic_tool} };
    const t = th.tool();

    const parsed = try root.parseTestArgs("{\"tool_name\":\"basic\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(result.success);
    // Should contain the fallback message
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sufficient") != null);
}
