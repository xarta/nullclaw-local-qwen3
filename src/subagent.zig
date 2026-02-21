//! SubagentManager — background task execution via isolated agent instances.
//!
//! Spawns subagents in separate OS threads with restricted tool sets
//! (no message, spawn, delegate — to prevent infinite loops).
//! Task results are routed via the event bus as system InboundMessages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus_mod = @import("bus.zig");
const config_mod = @import("config.zig");
const providers = @import("providers/root.zig");

const log = std.log.scoped(.subagent);

// ── Helpers ─────────────────────────────────────────────────────

/// Resolve a provider name to a full chat-completions URL.
///
/// For `"qwen3-local:<base-url>"` providers the base URL is extracted
/// and `/chat/completions` is appended if not already present.
/// All other provider names fall through to the legacy static
/// `providers.helpers.providerUrl()` map.
///
/// Caller owns the returned slice and must free it with `allocator`.
pub fn resolveProviderUrl(allocator: Allocator, provider_name: []const u8) ![]const u8 {
    const prefix = "qwen3-local:";
    if (std.mem.startsWith(u8, provider_name, prefix)) {
        const base = provider_name[prefix.len..];
        const trimmed = if (base.len > 0 and base[base.len - 1] == '/')
            base[0 .. base.len - 1]
        else
            base;
        if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
            return try allocator.dupe(u8, trimmed);
        }
        return try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
    }
    return try allocator.dupe(u8, providers.helpers.providerUrl(provider_name));
}

/// Determine whether `/no_think` should be prepended to a task prompt.
///
/// - `thinking_override = true`  → caller explicitly wants thinking  → return false (do NOT prepend)
/// - `thinking_override = false` → caller explicitly wants no-think  → return true  (DO prepend)
/// - `thinking_override = null`  → inherit `global_no_think` from config
pub fn shouldPrependNoThink(thinking_override: ?bool, global_no_think: bool) bool {
    if (thinking_override) |t| return !t;
    return global_no_think;
}

/// Build the effective task prompt, prepending `/no_think\n` when required.
/// Returns an owned slice; caller must free with `allocator`.
pub fn buildEffectiveTask(
    allocator: Allocator,
    task: []const u8,
    thinking_override: ?bool,
    global_no_think: bool,
) ![]const u8 {
    if (shouldPrependNoThink(thinking_override, global_no_think)) {
        return std.fmt.allocPrint(allocator, "/no_think\n{s}", .{task});
    }
    return allocator.dupe(u8, task);
}

/// Strip ALL `<think>...</think>` blocks from `text`.
/// Unlike `Qwen3LocalProvider.stripEmptyThinkBlock`, this removes blocks that
/// contain actual content (i.e. the subagent's chain-of-thought). A single
/// trailing newline after each closing tag is also consumed.
/// Returns an owned slice; caller must free with `allocator`.
pub fn stripThinkBlocks(allocator: Allocator, text: []const u8) ![]const u8 {
    const open = "<think>";
    const close = "</think>";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var pos: usize = 0;
    while (pos < text.len) {
        const think_start = std.mem.indexOfPos(u8, text, pos, open) orelse {
            try buf.appendSlice(allocator, text[pos..]);
            break;
        };
        try buf.appendSlice(allocator, text[pos..think_start]);
        const after_open = think_start + open.len;
        const think_end = std.mem.indexOfPos(u8, text, after_open, close) orelse {
            // No closing tag — keep everything from think_start onward as-is.
            try buf.appendSlice(allocator, text[think_start..]);
            break;
        };
        pos = think_end + close.len;
        // Consume one trailing newline so we don't leave a blank line.
        if (pos < text.len and text[pos] == '\n') pos += 1;
    }
    return buf.toOwnedSlice(allocator);
}


// ── Task types ──────────────────────────────────────────────────

pub const TaskStatus = enum {
    running,
    completed,
    failed,
};

pub const TaskState = struct {
    status: TaskStatus,
    label: []const u8,
    result: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,
    thread: ?std.Thread = null,
    /// When true, a result that trims to "LGTM" is silently discarded
    /// and not published to the outbound bus.  Used by auto-reflect.
    suppress_lgtm: bool = false,
};

pub const SubagentConfig = struct {
    max_iterations: u32 = 15,
    max_concurrent: u32 = 4,
};

// ── ThreadContext — passed to each spawned thread ────────────────

const ThreadContext = struct {
    manager: *SubagentManager,
    task_id: u64,
    task: []const u8,
    label: []const u8,
    origin_channel: []const u8,
    origin_chat_id: []const u8,
    /// Override the global no_think setting for this subagent.
    /// null = inherit from manager.no_think (global default)
    /// true  = force thinking mode  (do NOT prepend /no_think)
    /// false = force no-think mode  (DO prepend /no_think)
    thinking_override: ?bool = null,
    /// Max tokens for the subagent response. null = 4096 default.
    max_tokens: ?u64 = null,
};

// ── SubagentManager ─────────────────────────────────────────────

pub const SubagentManager = struct {
    allocator: Allocator,
    tasks: std.AutoHashMapUnmanaged(u64, *TaskState),
    next_id: u64,
    mutex: std.Thread.Mutex,
    config: SubagentConfig,
    bus: ?*bus_mod.Bus,

    // Context needed for creating providers in subagent threads
    api_key: ?[]const u8,
    default_provider: []const u8,
    default_model: ?[]const u8,
    workspace_dir: []const u8,
    agents: []const config_mod.NamedAgentConfig,
    http_enabled: bool,
    /// Global no_think setting derived from the default model config.
    /// Individual spawns can override this via thinking_override.
    no_think: bool,
    /// When true, `<think>...</think>` blocks are stripped from subagent
    /// results before publishing.  Derived from `cfg.defaultModelStripThinkTags()`.
    strip_think: bool = false,
    /// True while an auto-reflect subagent is in-flight.  Prevents stacking
    /// multiple simultaneous auto-reflects on consecutive turns.
    reflect_in_flight: bool = false,
    /// Channel/chat_id of the most recent user message — updated before each
    /// processMessage() call so spawn/reflect results are routed back correctly.
    current_channel: []const u8 = "system",
    current_chat_id: []const u8 = "agent",

    pub fn init(
        allocator: Allocator,
        cfg: *const config_mod.Config,
        bus: ?*bus_mod.Bus,
        subagent_config: SubagentConfig,
    ) SubagentManager {
        return .{
            .allocator = allocator,
            .tasks = .{},
            .next_id = 1,
            .mutex = .{},
            .config = subagent_config,
            .bus = bus,
            .api_key = cfg.defaultProviderKey(),
            .default_provider = cfg.default_provider,
            .default_model = cfg.default_model,
            .workspace_dir = cfg.workspace_dir,
            .agents = cfg.agents,
            .http_enabled = cfg.http_request.enabled,
            .no_think = cfg.defaultModelNoThink(),
            .strip_think = cfg.defaultModelStripThinkTags(),
        };
    }

    pub fn deinit(self: *SubagentManager) void {
        // Join all running threads and free task states
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| {
                thread.join();
            }
            if (state.result) |r| self.allocator.free(r);
            if (state.error_msg) |e| self.allocator.free(e);
            self.allocator.free(state.label);
            self.allocator.destroy(state);
        }
        self.tasks.deinit(self.allocator);
    }

    /// Spawn a background subagent. Returns task_id immediately.
    ///
    /// `opts.thinking_override`:
    ///   null  → inherit the global `no_think` flag from the config
    ///   true  → force thinking mode (skip /no_think prefix)
    ///   false → force no-think mode (prepend /no_think prefix)
    ///
    /// `opts.max_tokens`: token budget for the subagent response (null = 4096).
    pub fn spawn(
        self: *SubagentManager,
        task: []const u8,
        label: []const u8,
        origin_channel: []const u8,
        origin_chat_id: []const u8,
        opts: struct {
            thinking_override: ?bool = null,
            max_tokens: ?u64 = null,
            /// When true, a result of "LGTM" is silently discarded (not published).
            suppress_lgtm: bool = false,
        },
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.getRunningCountLocked() >= self.config.max_concurrent)
            return error.TooManyConcurrentSubagents;

        const task_id = self.next_id;
        self.next_id += 1;

        const state = try self.allocator.create(TaskState);
        state.* = .{
            .status = .running,
            .label = try self.allocator.dupe(u8, label),
            .started_at = std.time.milliTimestamp(),
            .suppress_lgtm = opts.suppress_lgtm,
        };

        try self.tasks.put(self.allocator, task_id, state);

        // Build thread context
        const ctx = try self.allocator.create(ThreadContext);
        ctx.* = .{
            .manager = self,
            .task_id = task_id,
            .task = try self.allocator.dupe(u8, task),
            .label = try self.allocator.dupe(u8, label),
            .origin_channel = try self.allocator.dupe(u8, origin_channel),
            .origin_chat_id = try self.allocator.dupe(u8, origin_chat_id),
            .thinking_override = opts.thinking_override,
            .max_tokens = opts.max_tokens,
        };

        state.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, subagentThreadFn, .{ctx});

        return task_id;
    }

    pub fn getTaskStatus(self: *SubagentManager, task_id: u64) ?TaskStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.status;
        }
        return null;
    }

    pub fn getTaskResult(self: *SubagentManager, task_id: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.result;
        }
        return null;
    }

    pub fn getRunningCount(self: *SubagentManager) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getRunningCountLocked();
    }

    fn getRunningCountLocked(self: *SubagentManager) u32 {
        var count: u32 = 0;
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.status == .running) count += 1;
        }
        return count;
    }

    /// Mark a task as completed or failed. Thread-safe.
    /// `origin_channel` / `origin_chat_id` are used to route the result back to
    /// the user via the outbound bus (picked up by the channel dispatcher).
    fn completeTask(self: *SubagentManager, task_id: u64, result: ?[]const u8, err_msg: ?[]const u8, origin_channel: []const u8, origin_chat_id: []const u8) void {
        // Dupe result/error into manager's allocator (source may be arena-backed).
        // Strip think blocks from successful results when strip_think is active.
        const raw_result = if (result) |r| self.allocator.dupe(u8, r) catch null else null;
        const owned_result: ?[]const u8 = if (raw_result) |r| blk: {
            if (self.strip_think) {
                const stripped = stripThinkBlocks(self.allocator, r) catch r;
                if (stripped.ptr != r.ptr) self.allocator.free(r);
                break :blk stripped;
            }
            break :blk r;
        } else null;
        const owned_err = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

        var label: []const u8 = "subagent";
        var suppress_lgtm: bool = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tasks.get(task_id)) |state| {
                state.status = if (owned_err != null) .failed else .completed;
                state.result = owned_result;
                state.error_msg = owned_err;
                state.completed_at = std.time.milliTimestamp();
                label = state.label;
                suppress_lgtm = state.suppress_lgtm;
            }
        }

        // Clear reflect_in_flight whenever an auto-reflect finishes.
        if (std.mem.startsWith(u8, label, "auto-reflect")) {
            self.reflect_in_flight = false;
        }

        // LGTM gate: suppress publish if the result is just "LGTM" and the
        // caller opted in (used by auto-reflect to avoid noise on good turns).
        if (suppress_lgtm) {
            if (owned_result) |r| {
                const trimmed = std.mem.trim(u8, r, " \t\n\r");
                if (std.mem.eql(u8, trimmed, "LGTM")) {
                    log.info("subagent '{s}': result is LGTM — suppressing publish", .{label});
                    return;
                }
            }
        }

        // Route result via bus (outside lock)
        if (self.bus) |b| {
            log.info("subagent: publishing result to outbound bus (channel={s} chat={s})", .{ origin_channel, origin_chat_id });
            const content = if (owned_result) |r|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' completed]\n{s}", .{ label, r }) catch return
            else if (owned_err) |e|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' failed]\n{s}", .{ label, e }) catch return
            else
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' finished]", .{label}) catch return;

            const msg = bus_mod.makeOutbound(
                self.allocator,
                origin_channel,
                origin_chat_id,
                content,
            ) catch {
                self.allocator.free(content);
                return;
            };
            self.allocator.free(content);

            b.publishOutbound(msg) catch |err| {
                log.err("subagent: failed to publish result to bus: {}", .{err});
            };
        } else {
            log.warn("subagent '{s}': no bus configured, result discarded", .{label});
        }
    }
};

// ── Thread function ─────────────────────────────────────────────

fn subagentThreadFn(ctx: *ThreadContext) void {
    defer {
        ctx.manager.allocator.free(ctx.task);
        ctx.manager.allocator.free(ctx.label);
        ctx.manager.allocator.free(ctx.origin_channel);
        ctx.manager.allocator.free(ctx.origin_chat_id);
        ctx.manager.allocator.destroy(ctx);
    }

    log.info("subagent '{s}' (task {d}): thread started, routing to {s}/{s}", .{ ctx.label, ctx.task_id, ctx.origin_channel, ctx.origin_chat_id });

    const system_prompt = "You are a background subagent. Complete the assigned task concisely and accurately. You have no access to interactive tools — focus on reasoning and analysis.";

    var cfg_arena = std.heap.ArenaAllocator.init(ctx.manager.allocator);
    defer cfg_arena.deinit();
    const arena = cfg_arena.allocator();

    // ── Determine effective task prompt ───────────────────────────────────
    const effective_task: []const u8 = buildEffectiveTask(
        arena,
        ctx.task,
        ctx.thinking_override,
        ctx.manager.no_think,
    ) catch {
        ctx.manager.completeTask(ctx.task_id, null, "OOM building effective task", ctx.origin_channel, ctx.origin_chat_id);
        return;
    };

    // ── Resolve provider URL ───────────────────────────────────────────────
    const provider_name = ctx.manager.default_provider;
    const full_url: []const u8 = resolveProviderUrl(arena, provider_name) catch {
        ctx.manager.completeTask(ctx.task_id, null, "OOM resolving provider URL", ctx.origin_channel, ctx.origin_chat_id);
        return;
    };

    const model = ctx.manager.default_model orelse "anthropic/claude-sonnet-4-5-20250929";
    const max_tok: u32 = if (ctx.max_tokens) |mt| @intCast(@min(mt, std.math.maxInt(u32))) else 4096;

    const result = providers.completeAtUrl(
        arena,
        full_url,
        ctx.manager.api_key,
        model,
        system_prompt,
        effective_task,
        0.7,
        max_tok,
    ) catch |err| {
        log.err("subagent '{s}' (task {d}): completeAtUrl failed: {s}", .{ ctx.label, ctx.task_id, @errorName(err) });
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err), ctx.origin_channel, ctx.origin_chat_id);
        return;
    };

    log.info("subagent '{s}' (task {d}): completed, publishing to {s}/{s}", .{ ctx.label, ctx.task_id, ctx.origin_channel, ctx.origin_chat_id });
    ctx.manager.completeTask(ctx.task_id, result, null, ctx.origin_channel, ctx.origin_chat_id);
}

// ── Tests ───────────────────────────────────────────────────────

test "SubagentManager init and deinit" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u64, 1), mgr.next_id);
    try std.testing.expect(mgr.bus == null);
}

test "SubagentConfig defaults" {
    const sc = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, 15), sc.max_iterations);
    try std.testing.expectEqual(@as(u32, 4), sc.max_concurrent);
}

test "TaskStatus enum values" {
    try std.testing.expect(@intFromEnum(TaskStatus.running) != @intFromEnum(TaskStatus.completed));
    try std.testing.expect(@intFromEnum(TaskStatus.completed) != @intFromEnum(TaskStatus.failed));
}

test "TaskState initial defaults" {
    const state = TaskState{
        .status = .running,
        .label = "test",
        .started_at = 0,
    };
    try std.testing.expect(state.result == null);
    try std.testing.expect(state.error_msg == null);
    try std.testing.expect(state.completed_at == null);
    try std.testing.expect(state.thread == null);
}

test "SubagentManager getRunningCount empty" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "SubagentManager getTaskStatus unknown id" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(999) == null);
}

test "SubagentManager getTaskResult unknown id" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskResult(999) == null);
}

test "SubagentManager completeTask updates state" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    // Manually insert a task state to test completeTask
    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "test-task"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "done!", null, "system", "agent");

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
    try std.testing.expectEqualStrings("done!", mgr.getTaskResult(1).?);
}

test "SubagentManager completeTask with error" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "fail-task"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, null, "timeout", "system", "agent");

    try std.testing.expectEqual(TaskStatus.failed, mgr.getTaskStatus(1).?);
    try std.testing.expect(mgr.getTaskResult(1) == null);
}

test "SubagentManager completeTask routes via bus" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "bus-task"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "result text", null, "telegram", "user123");

    // Check bus received the message — verify outbound depth increased
    try std.testing.expect(bus.outboundDepth() > 0);

    // Drain the bus to avoid memory leak
    bus.close();
    if (bus.consumeOutbound()) |msg| {
        msg.deinit(std.testing.allocator);
    }
}
test "SubagentManager stores no_think from config" {
    // no_think comes from cfg.defaultModelNoThink() — which returns false
    // for a config with no providers/models set.
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    // Default config has no Qwen3 model with no_think → false
    try std.testing.expectEqual(false, mgr.no_think);
}

test "ThreadContext thinking_override defaults to null" {
    const ctx = ThreadContext{
        .manager = undefined,
        .task_id = 1,
        .task = "test",
        .label = "test",
        .origin_channel = "system",
        .origin_chat_id = "agent",
    };
    try std.testing.expect(ctx.thinking_override == null);
    try std.testing.expect(ctx.max_tokens == null);
}

test "ThreadContext can set thinking_override true" {
    const ctx = ThreadContext{
        .manager = undefined,
        .task_id = 1,
        .task = "analyse this",
        .label = "thinker",
        .origin_channel = "system",
        .origin_chat_id = "agent",
        .thinking_override = true,
        .max_tokens = 2048,
    };
    try std.testing.expect(ctx.thinking_override.? == true);
    try std.testing.expectEqual(@as(?u64, 2048), ctx.max_tokens);
}

test "resolveProviderUrl handles qwen3-local prefix" {
    const url = try resolveProviderUrl(std.testing.allocator, "qwen3-local:https://litellm.example.com/v1");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://litellm.example.com/v1/chat/completions", url);
}

test "resolveProviderUrl trailing slash stripped" {
    const url = try resolveProviderUrl(std.testing.allocator, "qwen3-local:https://litellm.example.com/v1/");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://litellm.example.com/v1/chat/completions", url);
}

test "resolveProviderUrl already has chat/completions" {
    const url = try resolveProviderUrl(std.testing.allocator, "qwen3-local:https://litellm.example.com/v1/chat/completions");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://litellm.example.com/v1/chat/completions", url);
}

test "resolveProviderUrl openai falls back to static map" {
    const url = try resolveProviderUrl(std.testing.allocator, "openai");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", url);
}

test "resolveProviderUrl falls back to openrouter for unknown" {
    const url = try resolveProviderUrl(std.testing.allocator, "some-unknown-provider");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", url);
}

// ── shouldPrependNoThink tests ──────────────────────────────────

test "shouldPrependNoThink: override=true → false (thinking on)" {
    // Caller explicitly wants thinking — never prepend /no_think
    try std.testing.expect(!shouldPrependNoThink(true, true));
    try std.testing.expect(!shouldPrependNoThink(true, false));
}

test "shouldPrependNoThink: override=false → true (no-think forced)" {
    // Caller explicitly wants no-think — always prepend /no_think
    try std.testing.expect(shouldPrependNoThink(false, true));
    try std.testing.expect(shouldPrependNoThink(false, false));
}

test "shouldPrependNoThink: override=null inherits global" {
    // No override — follow global setting
    try std.testing.expect(shouldPrependNoThink(null, true));
    try std.testing.expect(!shouldPrependNoThink(null, false));
}

// ── buildEffectiveTask tests ────────────────────────────────────

test "buildEffectiveTask: thinking override=true → no prefix" {
    // Even when global no_think=true, override=true disables it
    const task = try buildEffectiveTask(std.testing.allocator, "hello", true, true);
    defer std.testing.allocator.free(task);
    try std.testing.expectEqualStrings("hello", task);
}

test "buildEffectiveTask: thinking override=false → /no_think prefix" {
    const task = try buildEffectiveTask(std.testing.allocator, "hello", false, false);
    defer std.testing.allocator.free(task);
    try std.testing.expectEqualStrings("/no_think\nhello", task);
}

test "buildEffectiveTask: override=null global=true → /no_think prefix" {
    // Standard testy config: no_think=true, no override → prefix applied
    const task = try buildEffectiveTask(std.testing.allocator, "what time is it?", null, true);
    defer std.testing.allocator.free(task);
    try std.testing.expectEqualStrings("/no_think\nwhat time is it?", task);
}

test "buildEffectiveTask: override=null global=false → no prefix" {
    // Model without no_think, no override → no prefix
    const task = try buildEffectiveTask(std.testing.allocator, "what time is it?", null, false);
    defer std.testing.allocator.free(task);
    try std.testing.expectEqualStrings("what time is it?", task);
}

test "buildEffectiveTask: reflect pattern — thinking forced on despite global no_think" {
    // Mirrors what reflect tool does: thinking_override=true, global no_think=true
    const original = "Did I miss anything the user was implying?";
    const task = try buildEffectiveTask(std.testing.allocator, original, true, true);
    defer std.testing.allocator.free(task);
    // Must NOT have /no_think prefix
    try std.testing.expect(!std.mem.startsWith(u8, task, "/no_think"));
    try std.testing.expectEqualStrings(original, task);
}

// ── stripThinkBlocks tests ──────────────────────────────────────

test "stripThinkBlocks: no think block passthrough" {
    const input = "Hello, world!";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello, world!", result);
}

test "stripThinkBlocks: strips non-empty think block" {
    const input = "<think>some reasoning here</think>The answer is 42.";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("The answer is 42.", result);
}

test "stripThinkBlocks: strips empty think block" {
    const input = "<think></think>Clean output.";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Clean output.", result);
}

test "stripThinkBlocks: consumes trailing newline after block" {
    const input = "<think>reasoning</think>\nThe answer is 42.";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("The answer is 42.", result);
}

test "stripThinkBlocks: multiple think blocks" {
    const input = "<think>first</think>Middle.<think>second</think>End.";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Middle.End.", result);
}

test "stripThinkBlocks: unclosed think tag kept as-is" {
    const input = "<think>no closing tag";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<think>no closing tag", result);
}

test "stripThinkBlocks: multiline content" {
    const input = "<think>\nline one\nline two\n</think>\nActual response.";
    const result = try stripThinkBlocks(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Actual response.", result);
}

// ── LGTM gate tests ─────────────────────────────────────────────

test "completeTask: LGTM result suppressed when suppress_lgtm=true" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "auto-reflect"),
        .started_at = std.time.milliTimestamp(),
        .suppress_lgtm = true,
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "LGTM", null, "telegram", "user123");

    // Bus outbound should be empty — LGTM was suppressed
    try std.testing.expectEqual(@as(usize, 0), bus.outboundDepth());
    // Status should still be updated
    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
}

test "completeTask: non-LGTM result published even with suppress_lgtm=true" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "auto-reflect"),
        .started_at = std.time.milliTimestamp(),
        .suppress_lgtm = true,
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "I should correct myself — the correct answer is 42.", null, "telegram", "user123");

    // Bus should have the correction
    try std.testing.expect(bus.outboundDepth() > 0);
    bus.close();
    if (bus.consumeOutbound()) |msg| {
        msg.deinit(std.testing.allocator);
    }
}

test "completeTask: reflect_in_flight cleared for auto-reflect label" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    mgr.reflect_in_flight = true;

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "auto-reflect"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "done", null, "system", "agent");

    try std.testing.expectEqual(false, mgr.reflect_in_flight);
}

test "stripThinkBlocks exported via providers root" {
    // Structural: just confirm the function is callable from this module
    const result = try stripThinkBlocks(std.testing.allocator, "plain text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

