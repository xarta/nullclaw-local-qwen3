//! Channel Loop — extracted polling loops for daemon-supervised channels.
//!
//! Contains `ChannelRuntime` (shared dependencies for message processing)
//! and `runTelegramLoop` (the polling thread function spawned by the
//! daemon supervisor).

const std = @import("std");
const Config = @import("config.zig").Config;
const telegram = @import("channels/telegram.zig");
const session_mod = @import("session.zig");
const providers = @import("providers/root.zig");
const memory_mod = @import("memory/root.zig");
const observability = @import("observability.zig");
const tools_mod = @import("tools/root.zig");
const mcp = @import("mcp.zig");
const voice = @import("voice.zig");
const health = @import("health.zig");
const daemon = @import("daemon.zig");
const subagent_mod = @import("subagent.zig");
const bus_mod = @import("bus.zig");

const log = std.log.scoped(.channel_loop);

// ════════════════════════════════════════════════════════════════════════════
// TelegramLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const TelegramLoopState = struct {
    /// Updated after each pollUpdates() — epoch seconds.
    last_activity: std.atomic.Value(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: std.atomic.Value(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() TelegramLoopState {
        return .{
            .last_activity = std.atomic.Value(i64).init(std.time.timestamp()),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }
};

// Re-export centralized ProviderHolder from providers module.
pub const ProviderHolder = providers.ProviderHolder;

// ════════════════════════════════════════════════════════════════════════════
// ChannelRuntime — container for polling-thread dependencies
// ════════════════════════════════════════════════════════════════════════════

pub const ChannelRuntime = struct {
    allocator: std.mem.Allocator,
    session_mgr: session_mod.SessionManager,
    provider_holder: *ProviderHolder,
    tools: []const tools_mod.Tool,
    mem: ?memory_mod.Memory,
    noop_obs: *observability.NoopObserver,
    subagent_manager: *subagent_mod.SubagentManager,

    /// Initialize the runtime from config — mirrors main.zig:702-786 setup.
    pub fn init(allocator: std.mem.Allocator, config: *const Config, bus: ?*bus_mod.Bus) !*ChannelRuntime {
        // Provider — heap-allocated for vtable pointer stability
        const holder = try allocator.create(ProviderHolder);
        errdefer allocator.destroy(holder);

        holder.* = ProviderHolder.fromConfig(allocator, config.default_provider, config.defaultProviderKey(), .{ .qwen3_no_think = config.defaultModelNoThink(), .qwen3_strip_think_tags = config.defaultModelStripThinkTags() });

        const provider_i = holder.provider();

        // MCP tools
        const mcp_tools: ?[]const tools_mod.Tool = if (config.mcp_servers.len > 0)
            mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
                log.warn("MCP init failed: {}", .{err});
                break :blk null;
            }
        else
            null;

        // Optional memory backend (created first so tools can be wired to it)
        var mem_opt: ?memory_mod.Memory = null;
        const db_path = std.fs.path.joinZ(allocator, &.{ config.workspace_dir, "memory.db" }) catch null;
        defer if (db_path) |p| allocator.free(p);
        if (db_path) |p| {
            if (memory_mod.createMemory(allocator, config.memory.backend, p)) |mem| {
                mem_opt = mem;
            } else |err| {
                log.err("createMemory failed: {s}", .{@errorName(err)});
            }
        }

        // SubagentManager — heap-allocated so pointer stays valid for tool lifetime
        const sub_mgr = try allocator.create(subagent_mod.SubagentManager);
        errdefer allocator.destroy(sub_mgr);
        sub_mgr.* = subagent_mod.SubagentManager.init(allocator, config, bus, .{});
        errdefer sub_mgr.deinit();

        // Tools
        const tools = tools_mod.allTools(allocator, config.workspace_dir, .{
            .http_enabled = config.http_request.enabled,
            .browser_enabled = config.browser.enabled,
            .screenshot_enabled = true,
            .mcp_tools = mcp_tools,
            .agents = config.agents,
            .fallback_api_key = config.defaultProviderKey(),
            .tools_config = config.tools,
            .memory = mem_opt,
            .subagent_manager = sub_mgr,
        }) catch &.{};
        errdefer if (tools.len > 0) allocator.free(tools);

        // Noop observer (heap for vtable stability)
        const noop_obs = try allocator.create(observability.NoopObserver);
        errdefer allocator.destroy(noop_obs);
        noop_obs.* = .{};
        const obs = noop_obs.observer();

        // Session manager
        var session_mgr = session_mod.SessionManager.init(allocator, config, provider_i, tools, mem_opt, obs);
        // Wire the subagent manager so agents can auto-trigger background reflect.
        session_mgr.subagent_manager = sub_mgr;

        // Self — heap-allocated so pointers remain stable
        const self = try allocator.create(ChannelRuntime);
        self.* = .{
            .allocator = allocator,
            .session_mgr = session_mgr,
            .provider_holder = holder,
            .tools = tools,
            .mem = mem_opt,
            .noop_obs = noop_obs,
            .subagent_manager = sub_mgr,
        };
        return self;
    }

    pub fn deinit(self: *ChannelRuntime) void {
        const alloc = self.allocator;
        self.session_mgr.deinit();
        if (self.tools.len > 0) alloc.free(self.tools);
        alloc.destroy(self.noop_obs);
        self.subagent_manager.deinit();
        alloc.destroy(self.subagent_manager);
        alloc.destroy(self.provider_holder);
        alloc.destroy(self);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// MsgJob — per-message thread context for concurrent session processing
// ════════════════════════════════════════════════════════════════════════════

/// Context for a single Telegram message processed in its own thread.
/// Allocated with std.heap.c_allocator (always thread-safe) and freed by the
/// thread when complete.
///
/// Thread-safety notes
/// ───────────────────
/// • SessionManager (session.zig) is thread-safe: a per-session mutex
///   serialises turns within the same chat; different chats run in parallel.
/// • origin_channel / origin_chat_id are stamped directly onto the per-session
///   Agent via processMessageWithContext — no shared-manager race.
///   without a lock.  If two threads run concurrently they will race, but the
///   worst outcome is one reflect result being routed to the wrong chat.  This
///   is a known, acceptable trade-off until a per-session SubagentManager is
///   implemented.
/// • The `allocator` field is used to free() the reply returned by
///   processMessage().  In ReleaseSmall (the production build mode) this is
///   std.heap.smp_allocator which is thread-safe.
const MsgJob = struct {
    /// Main allocator — used to free processMessage reply. Thread-safe in prod.
    allocator: std.mem.Allocator,
    tg: *telegram.TelegramChannel,
    session_mgr: *session_mod.SessionManager,
    subagent_manager: *subagent_mod.SubagentManager,
    sender: []u8,   // owned (c_allocator), freed by thread
    content: []u8,  // owned (c_allocator), freed by thread
    reply_to_id: ?i64,

    pub fn run(ctx: *MsgJob) void {
        defer {
            std.heap.c_allocator.free(ctx.sender);
            std.heap.c_allocator.free(ctx.content);
            std.heap.c_allocator.destroy(ctx);
        }

        var typing = telegram.TypingIndicator.init(ctx.tg);
        typing.start(ctx.sender);

        var key_buf: [128]u8 = undefined;
        const session_key = std.fmt.bufPrint(&key_buf, "telegram:{s}", .{ctx.sender}) catch ctx.sender;

        // Use processMessageWithContext to stamp origin_channel/origin_chat_id
        // directly onto the per-session Agent — avoids the race where a second
        // concurrent MsgJob overwrites SubagentManager.current_channel/chat_id
        // before the first agent's auto-reflect fires.
        const reply = ctx.session_mgr.processMessageWithContext(session_key, ctx.content, "telegram", ctx.sender) catch |err| {
            typing.stop();
            log.err("message thread: agent error: {}", .{err});
            const err_text: []const u8 = switch (err) {
                error.CurlFailed, error.CurlReadError, error.CurlWaitError => "Network error. Please try again.",
                error.OutOfMemory => "Out of memory.",
                else => "An error occurred. Try again or /new for a fresh session.",
            };
            ctx.tg.sendMessageWithReply(ctx.sender, err_text, ctx.reply_to_id) catch |e|
                log.err("failed to send error reply: {}", .{e});
            return;
        };
        defer ctx.allocator.free(reply);

        typing.stop();
        ctx.tg.sendMessageWithReply(ctx.sender, reply, ctx.reply_to_id) catch |err|
            log.warn("message thread: send error: {}", .{err});
    }
};

/// Allocate a MsgJob and spawn a detached thread to process the message.
/// Returns true on success; caller should fall back to inline processing on false.
fn spawnMsgJob(
    allocator: std.mem.Allocator,
    tg: *telegram.TelegramChannel,
    runtime: *ChannelRuntime,
    sender: []const u8,
    content: []const u8,
    reply_to_id: ?i64,
) bool {
    const ctx = std.heap.c_allocator.create(MsgJob) catch return false;

    ctx.* = .{
        .allocator = allocator,
        .tg = tg,
        .session_mgr = &runtime.session_mgr,
        .subagent_manager = runtime.subagent_manager,
        .sender = std.heap.c_allocator.dupe(u8, sender) catch {
            std.heap.c_allocator.destroy(ctx);
            return false;
        },
        .content = std.heap.c_allocator.dupe(u8, content) catch {
            std.heap.c_allocator.free(ctx.sender);
            std.heap.c_allocator.destroy(ctx);
            return false;
        },
        .reply_to_id = reply_to_id,
    };

    const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, MsgJob.run, .{ctx}) catch {
        std.heap.c_allocator.free(ctx.sender);
        std.heap.c_allocator.free(ctx.content);
        std.heap.c_allocator.destroy(ctx);
        return false;
    };
    t.detach();
    return true;
}

// ════════════════════════════════════════════════════════════════════════════
// runTelegramLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for the Telegram polling loop.
/// Mirrors main.zig:793-866 but checks `loop_state.stop_requested` and
/// `daemon.isShutdownRequested()` for graceful shutdown.
pub fn runTelegramLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *TelegramLoopState,
) void {
    const telegram_config = config.channels.telegram orelse return;

    // Heap-alloc TelegramChannel for vtable pointer stability
    const tg_ptr = allocator.create(telegram.TelegramChannel) catch return;
    defer allocator.destroy(tg_ptr);
    tg_ptr.* = telegram.TelegramChannel.init(allocator, telegram_config.bot_token, telegram_config.allow_from);
    tg_ptr.proxy = telegram_config.proxy;

    // Set up transcription — key comes from providers.{audio_media.provider}
    const trans = config.audio_media;
    if (config.getProviderKey(trans.provider)) |key| {
        const wt = allocator.create(voice.WhisperTranscriber) catch {
            log.warn("Failed to allocate WhisperTranscriber", .{});
            return;
        };
        wt.* = .{
            .endpoint = voice.resolveTranscriptionEndpoint(trans.provider, trans.base_url),
            .api_key = key,
            .model = trans.model,
            .language = trans.language,
        };
        tg_ptr.transcriber = wt.transcriber();
    }

    // Register bot commands and skip stale messages
    tg_ptr.setMyCommands();
    tg_ptr.dropPendingUpdates();

    var evict_counter: u32 = 0;

    const model = config.default_model orelse "anthropic/claude-sonnet-4";

    // Update activity timestamp at start
    loop_state.last_activity.store(std.time.timestamp(), .release);

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = tg_ptr.pollUpdates(allocator) catch |err| {
            log.warn("Telegram poll error: {}", .{err});
            loop_state.last_activity.store(std.time.timestamp(), .release);
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        // Update activity after each poll (even if no messages)
        loop_state.last_activity.store(std.time.timestamp(), .release);

        for (messages) |msg| {
            // Handle /start command inline (fast, no LLM call)
            const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullClaw.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullClaw. Type /help for commands.";
                tg_ptr.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                continue;
            }

            // Reply-to logic
            const use_reply_to = msg.is_group or telegram_config.reply_in_private;
            const reply_to_id: ?i64 = if (use_reply_to) msg.message_id else null;

            // Spawn a thread for this message so the poll loop stays responsive.
            // If spawn fails (OOM / too many threads), fall back to inline processing.
            if (!spawnMsgJob(allocator, tg_ptr, runtime, msg.sender, msg.content, reply_to_id)) {
                // Inline fallback: same logic as before threading was added.
                log.warn("spawnMsgJob failed; processing inline for sender={s}", .{msg.sender});

                var key_buf: [128]u8 = undefined;
                const session_key = std.fmt.bufPrint(&key_buf, "telegram:{s}", .{msg.sender}) catch msg.sender;

                var typing_fb = telegram.TypingIndicator.init(tg_ptr);
                typing_fb.start(msg.sender);

                const reply = runtime.session_mgr.processMessageWithContext(session_key, msg.content, "telegram", msg.sender) catch |err| {
                    typing_fb.stop();
                    log.err("Agent error (inline): {}", .{err});
                    const err_msg: []const u8 = switch (err) {
                        error.CurlFailed, error.CurlReadError, error.CurlWaitError => "Network error. Please try again.",
                        error.OutOfMemory => "Out of memory.",
                        else => "An error occurred. Try again or /new for a fresh session.",
                    };
                    tg_ptr.sendMessageWithReply(msg.sender, err_msg, reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
                    continue;
                };
                defer allocator.free(reply);

                typing_fb.stop();
                tg_ptr.sendMessageWithReply(msg.sender, reply, reply_to_id) catch |err| {
                    log.warn("Send error (inline): {}", .{err});
                };
            }
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }

        health.markComponentOk("telegram");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "TelegramLoopState init defaults" {
    const state = TelegramLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "TelegramLoopState stop_requested toggle" {
    var state = TelegramLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "TelegramLoopState last_activity update" {
    var state = TelegramLoopState.init();
    const before = state.last_activity.load(.acquire);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.last_activity.store(std.time.timestamp(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "ProviderHolder tagged union fields" {
    // Compile-time check that ProviderHolder has expected variants
    try std.testing.expect(@hasField(ProviderHolder, "openrouter"));
    try std.testing.expect(@hasField(ProviderHolder, "anthropic"));
    try std.testing.expect(@hasField(ProviderHolder, "openai"));
    try std.testing.expect(@hasField(ProviderHolder, "gemini"));
    try std.testing.expect(@hasField(ProviderHolder, "ollama"));
    try std.testing.expect(@hasField(ProviderHolder, "compatible"));
    try std.testing.expect(@hasField(ProviderHolder, "openai_codex"));
}
