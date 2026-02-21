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
    fn completeTask(self: *SubagentManager, task_id: u64, result: ?[]const u8, err_msg: ?[]const u8) void {
        // Dupe result/error into manager's allocator (source may be arena-backed)
        const owned_result = if (result) |r| self.allocator.dupe(u8, r) catch null else null;
        const owned_err = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

        var label: []const u8 = "subagent";
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tasks.get(task_id)) |state| {
                state.status = if (owned_err != null) .failed else .completed;
                state.result = owned_result;
                state.error_msg = owned_err;
                state.completed_at = std.time.milliTimestamp();
                label = state.label;
            }
        }

        // Route result via bus (outside lock)
        if (self.bus) |b| {
            const content = if (owned_result) |r|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' completed]\n{s}", .{ label, r }) catch return
            else if (owned_err) |e|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' failed]\n{s}", .{ label, e }) catch return
            else
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' finished]", .{label}) catch return;

            const msg = bus_mod.makeInbound(
                self.allocator,
                "system",
                "subagent",
                "agent",
                content,
                "system:subagent",
            ) catch {
                self.allocator.free(content);
                return;
            };
            self.allocator.free(content);

            b.publishInbound(msg) catch |err| {
                log.err("subagent: failed to publish result to bus: {}", .{err});
            };
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

    const system_prompt = "You are a background subagent. Complete the assigned task concisely and accurately. You have no access to interactive tools — focus on reasoning and analysis.";

    var cfg_arena = std.heap.ArenaAllocator.init(ctx.manager.allocator);
    defer cfg_arena.deinit();
    const arena = cfg_arena.allocator();

    // ── Determine effective thinking mode ──────────────────────────────────
    // thinking_override=true  → force thinking  (never prepend /no_think)
    // thinking_override=false → force no-think  (always prepend /no_think)
    // thinking_override=null  → inherit global no_think flag from config
    const want_no_think: bool = if (ctx.thinking_override) |t| !t else ctx.manager.no_think;

    // Prepend /no_think pragma to the user prompt when needed.
    // Qwen3 only honours the pragma in the user turn, not in system prompt.
    const effective_task: []const u8 = if (want_no_think)
        std.fmt.allocPrint(arena, "/no_think\n{s}", .{ctx.task}) catch ctx.task
    else
        ctx.task;

    // ── Resolve provider URL ───────────────────────────────────────────────
    // Legacy helpers.providerUrl() uses a static compile-time map that does
    // not know about runtime "qwen3-local:<url>" provider strings.  Extract
    // the base URL directly when that prefix is present.
    const provider_name = ctx.manager.default_provider;
    const full_url: []const u8 = resolveProviderUrl(arena, provider_name) catch {
        ctx.manager.completeTask(ctx.task_id, null, "OOM resolving provider URL");
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
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };

    ctx.manager.completeTask(ctx.task_id, result, null);
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

    mgr.completeTask(1, "done!", null);

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

    mgr.completeTask(1, null, "timeout");

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

    mgr.completeTask(1, "result text", null);

    // Check bus received the message — verify depth increased
    try std.testing.expect(bus.inboundDepth() > 0);

    // Drain the bus to avoid memory leak
    bus.close();
    if (bus.consumeInbound()) |msg| {
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
