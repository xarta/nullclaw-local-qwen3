const std = @import("std");
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const MemoryEntry = memory_mod.MemoryEntry;

// ═══════════════════════════════════════════════════════════════════════════
// Memory Loader — inject relevant memory context into user messages
// ═══════════════════════════════════════════════════════════════════════════

/// Default number of memory entries to recall per query.
const DEFAULT_RECALL_LIMIT: usize = 5;

/// Build a memory context preamble by searching stored memories.
///
/// Returns a formatted string like:
/// ```
/// [Memory context]
/// - key1: value1
/// - key2: value2
/// ```
///
/// Returns an empty owned string if no relevant memories are found.
pub fn loadContext(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
) ![]const u8 {
    const entries = mem.recall(allocator, user_message, DEFAULT_RECALL_LIMIT, null) catch {
        return try allocator.dupe(u8, "");
    };
    defer memory_mod.freeEntries(allocator, entries);

    if (entries.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Filter out autosave_* entries (raw conversation replays) — they are already
    // present in the HISTORY section and, crucially, autosave_assistant_* entries
    // contain previous model outputs that may be wrong/contradictory, which causes
    // the model to anchor on them and ignore factual core memories.
    var factual_count: usize = 0;
    for (entries) |entry| {
        if (std.mem.startsWith(u8, entry.key, "autosave_")) continue;
        factual_count += 1;
    }

    if (factual_count == 0) {
        return try allocator.dupe(u8, "");
    }

    try w.writeAll("[Memory context]\n");
    for (entries) |entry| {
        if (std.mem.startsWith(u8, entry.key, "autosave_")) continue;
        try std.fmt.format(w, "- {s}: {s}\n", .{ entry.key, entry.content });
    }
    try w.writeAll("\n");

    return try buf.toOwnedSlice(allocator);
}

/// Enrich a user message with memory context prepended.
/// If no context is available, returns an owned dupe of the original message.
pub fn enrichMessage(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
) ![]const u8 {
    const context = try loadContext(allocator, mem, user_message);
    if (context.len == 0) {
        allocator.free(context);
        return try allocator.dupe(u8, user_message);
    }

    defer allocator.free(context);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ context, user_message });
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "loadContext returns empty for no-op memory" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const context = try loadContext(allocator, mem, "hello");
    defer allocator.free(context);

    try std.testing.expectEqualStrings("", context);
}

test "enrichMessage with no context returns original" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const enriched = try enrichMessage(allocator, mem, "hello");
    defer allocator.free(enriched);

    try std.testing.expectEqualStrings("hello", enriched);
}

test "loadContext filters out autosave_assistant entries" {
    const sqlite_mod = @import("../memory/sqlite.zig");
    const allocator = std.testing.allocator;
    var sq = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer sq.deinit();
    const mem = sq.memory();

    // Store a real fact and an autosave_assistant entry (simulating a previous wrong response)
    try mem.store("birthday", "18th August 1973", .core, null);
    try mem.store("autosave_assistant_123", "I don't have access to your personal information", .daily, null);

    const context = try loadContext(allocator, mem, "birthday august");
    defer allocator.free(context);

    // The birthday fact should appear
    try std.testing.expect(std.mem.indexOf(u8, context, "birthday") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "18th August 1973") != null);
    // The autosave_assistant entry must NOT appear
    try std.testing.expect(std.mem.indexOf(u8, context, "autosave_assistant") == null);
}

test "loadContext filters out autosave_user entries" {
    const sqlite_mod = @import("../memory/sqlite.zig");
    const allocator = std.testing.allocator;
    var sq = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer sq.deinit();
    const mem = sq.memory();

    try mem.store("name", "David", .core, null);
    try mem.store("autosave_user_456", "Tell me about yourself", .conversation, null);

    const context = try loadContext(allocator, mem, "name david");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "David") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "autosave_user") == null);
}

test "loadContext returns empty when only autosave entries match" {
    const sqlite_mod = @import("../memory/sqlite.zig");
    const allocator = std.testing.allocator;
    var sq = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer sq.deinit();
    const mem = sq.memory();

    try mem.store("autosave_assistant_789", "I can help you with that", .daily, null);
    try mem.store("autosave_user_790", "Can you help me?", .conversation, null);

    const context = try loadContext(allocator, mem, "help");
    defer allocator.free(context);

    // All entries are autosave — context should be empty
    try std.testing.expectEqualStrings("", context);
}
