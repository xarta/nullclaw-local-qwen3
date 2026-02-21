//! Provider for locally-hosted Qwen3 models reached via an OpenAI-compatible
//! endpoint (e.g. a LiteLLM proxy fronting vLLM).
//!
//! Three behaviours distinguish this from the generic OpenAI-compatible provider:
//!
//! 1. `/no_think\n` is prepended to every outgoing user message when the model
//!    entry has `no_think: true` in config.json.
//!    Qwen3 only honours the pragma when it appears in the *user* turn —
//!    placing it in the system prompt has no effect.
//!
//! 2. Empty `<think>\s*</think>` blocks are stripped from responses when
//!    `no_think` is active.  Even with the pragma, the model still emits a
//!    vestigial `<think>\n\n</think>` prefix that we don't want to surface.
//!
//! 3. `supportsNativeTools()` returns false, so the agent uses XML <tool_call>
//!    formatting.  Qwen3 served through vLLM/LiteLLM confabulates tool
//!    execution when the structured OpenAI tools array is present.
//!
//! HTTP transport, JSON serialisation, and response parsing are delegated to
//! `OpenAiCompatibleProvider`.

const std = @import("std");
const root = @import("root.zig");
const compatible = @import("compatible.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const StreamCallback = root.StreamCallback;
const StreamChunk = root.StreamChunk;
const StreamChatResult = root.StreamChatResult;

/// Pragma that disables Qwen3 chain-of-thought.  Must appear in the user turn.
const NO_THINK_PREFIX = "/no_think\n";

pub const Qwen3LocalProvider = struct {
    /// Underlying OpenAI-compatible transport.
    inner: compatible.OpenAiCompatibleProvider,
    allocator: std.mem.Allocator,
    /// When true, `/no_think\n` is prepended to user messages, disabling
    /// Qwen3 chain-of-thought.  Derived from `no_think: true` on the model
    /// entry in the provider's model list in config.json.
    no_think: bool,
    /// When true, empty `<think>\s*</think>` blocks are stripped from
    /// responses.  Also implied when `no_think` is true.  Use this to strip
    /// think tags while still allowing chain-of-thought.
    strip_think_tags: bool,

    /// True when response post-processing should strip empty think blocks.
    inline fn shouldStrip(self: Qwen3LocalProvider) bool {
        return self.no_think or self.strip_think_tags;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        api_key: ?[]const u8,
        no_think: bool,
        strip_think_tags: bool,
    ) Qwen3LocalProvider {
        return .{
            .inner = compatible.OpenAiCompatibleProvider.init(
                allocator,
                "Qwen3 (local)",
                base_url,
                api_key,
                .bearer,
            ),
            .allocator = allocator,
            .no_think = no_think,
            .strip_think_tags = strip_think_tags,
        };
    }

    /// Build a Provider interface from this Qwen3LocalProvider.
    pub fn provider(self: *Qwen3LocalProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Return an owned copy of `msg` with NO_THINK_PREFIX prepended.
    pub fn prependNoThink(allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ NO_THINK_PREFIX, msg });
    }

    /// Build a modified messages slice with NO_THINK_PREFIX prepended to every
    /// user-role message.  Non-user messages borrow from the original slice
    /// (no allocation).  Caller must free each user message content and the
    /// returned slice itself.
    fn buildPrefixedMessages(
        allocator: std.mem.Allocator,
        messages: []const root.ChatMessage,
    ) ![]root.ChatMessage {
        const out = try allocator.alloc(root.ChatMessage, messages.len);
        var n_prefixed: usize = 0;
        errdefer {
            // Free only the strings we successfully allocated.
            var freed: usize = 0;
            for (out) |msg| {
                if (freed >= n_prefixed) break;
                if (msg.role == .user) {
                    allocator.free(msg.content);
                    freed += 1;
                }
            }
            allocator.free(out);
        }
        for (messages, 0..) |msg, i| {
            if (msg.role == .user) {
                var copy = msg;
                copy.content = try prependNoThink(allocator, msg.content);
                out[i] = copy;
                n_prefixed += 1;
            } else {
                out[i] = msg;
            }
        }
        return out;
    }

    /// Free a slice returned by buildPrefixedMessages.
    fn freePrefixedMessages(allocator: std.mem.Allocator, msgs: []root.ChatMessage) void {
        for (msgs) |msg| {
            if (msg.role == .user) allocator.free(msg.content);
        }
        allocator.free(msgs);
    }

    // ── Response post-processing ──────────────────────────────────────────────

    /// Return an owned copy of `text` with a leading `<think>\s*</think>` block
    /// stripped.  If the think block is non-empty (contains non-whitespace), or
    /// if `text` does not start with `<think>`, an owned copy of the original
    /// is returned unchanged.
    pub fn stripEmptyThinkBlock(
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]const u8 {
        const open = "<think>";
        const close = "</think>";
        if (!std.mem.startsWith(u8, text, open)) return allocator.dupe(u8, text);
        const after_open = text[open.len..];
        const rel = std.mem.indexOf(u8, after_open, close) orelse return allocator.dupe(u8, text);
        // Validate that everything between the tags is whitespace.
        for (after_open[0..rel]) |c| {
            switch (c) {
                ' ', '\t', '\n', '\r' => {},
                else => return allocator.dupe(u8, text),
            }
        }
        // Skip leading whitespace after </think>.
        const rest = after_open[rel + close.len..];
        var start: usize = 0;
        while (start < rest.len) : (start += 1) {
            switch (rest[start]) {
                ' ', '\t', '\n', '\r' => {},
                else => break,
            }
        }
        return allocator.dupe(u8, rest[start..]);
    }

    /// Streaming callback wrapper that strips a leading empty
    /// `<think>\s*</think>` block from the streamed output.
    /// Instantiate on the stack, pass `StreamThinkFilter.callback` and a
    /// pointer to the struct as the callback/context pair, then call `deinit`
    /// after the stream completes.
    const StreamThinkFilter = struct {
        allocator: std.mem.Allocator,
        buf: std.ArrayListUnmanaged(u8),
        forwarding: bool,
        /// True after stripping an empty think block when we still need to
        /// consume leading whitespace from the next arriving chunk(s).
        eat_leading_ws: bool,
        outer_cb: StreamCallback,
        outer_ctx: *anyopaque,

        const OPEN = "<think>";
        const CLOSE = "</think>";
        /// Safety valve: if the buffer grows beyond this without finding
        /// </think>, we flush and switch to passthrough.
        const MAX_BUF: usize = 8192;

        fn init(
            alloc: std.mem.Allocator,
            outer_cb: StreamCallback,
            outer_ctx: *anyopaque,
        ) StreamThinkFilter {
            return .{
                .allocator = alloc,
                .buf = .empty,
                .forwarding = false,
                .eat_leading_ws = false,
                .outer_cb = outer_cb,
                .outer_ctx = outer_ctx,
            };
        }

        fn deinit(self: *StreamThinkFilter) void {
            self.buf.deinit(self.allocator);
        }

        fn flushAndForward(self: *StreamThinkFilter) void {
            if (self.buf.items.len > 0) {
                self.outer_cb(self.outer_ctx, StreamChunk.textDelta(self.buf.items));
                self.buf.clearRetainingCapacity();
            }
            self.forwarding = true;
        }

        fn callback(ctx_ptr: *anyopaque, chunk: StreamChunk) void {
            const self: *StreamThinkFilter = @ptrCast(@alignCast(ctx_ptr));

            if (chunk.is_final) {
                // Flush any un-forwarded buffer before the final sentinel.
                if (!self.forwarding) self.flushAndForward();
                self.outer_cb(self.outer_ctx, chunk);
                return;
            }

            if (self.forwarding) {
                if (self.eat_leading_ws) {
                    // Strip leading whitespace from this chunk.
                    var start: usize = 0;
                    while (start < chunk.delta.len) : (start += 1) {
                        switch (chunk.delta[start]) {
                            ' ', '\t', '\n', '\r' => {},
                            else => break,
                        }
                    }
                    if (start < chunk.delta.len) {
                        self.eat_leading_ws = false;
                        self.outer_cb(self.outer_ctx, StreamChunk.textDelta(chunk.delta[start..]));
                    }
                    // If the whole chunk was whitespace, eat_leading_ws stays true.
                    return;
                }
                self.outer_cb(self.outer_ctx, chunk);
                return;
            }

            // Buffering: accumulate until we can decide.
            self.buf.appendSlice(self.allocator, chunk.delta) catch {
                // OOM — flush and passthrough.
                self.flushAndForward();
                if (chunk.delta.len > 0) self.outer_cb(self.outer_ctx, chunk);
                return;
            };

            if (!std.mem.startsWith(u8, self.buf.items, OPEN)) {
                // No <think> at start — pass through as-is.
                self.flushAndForward();
                return;
            }

            // We have a <think> prefix.  Wait for </think>.
            if (std.mem.indexOf(u8, self.buf.items[OPEN.len..], CLOSE)) |rel| {
                const between = self.buf.items[OPEN.len .. OPEN.len + rel];
                var only_ws = true;
                for (between) |c| {
                    switch (c) {
                        ' ', '\t', '\n', '\r' => {},
                        else => { only_ws = false; break; },
                    }
                }
                if (only_ws) {
                    // Empty think block — strip it plus any buffered whitespace
                    // after </think>.  Any remaining whitespace in subsequent
                    // chunks is handled by eat_leading_ws.
                    const after_close = self.buf.items[OPEN.len + rel + CLOSE.len..];
                    var start: usize = 0;
                    while (start < after_close.len) : (start += 1) {
                        switch (after_close[start]) {
                            ' ', '\t', '\n', '\r' => {},
                            else => break,
                        }
                    }
                    if (start < after_close.len) {
                        self.outer_cb(
                            self.outer_ctx,
                            StreamChunk.textDelta(after_close[start..]),
                        );
                    } else {
                        // No real content yet — eat whitespace from next chunk.
                        self.eat_leading_ws = true;
                    }
                } else {
                    // Non-empty think block — forward as-is.
                    self.outer_cb(self.outer_ctx, StreamChunk.textDelta(self.buf.items));
                }
                self.buf.clearRetainingCapacity();
                self.forwarding = true;
                return;
            }

            // Still waiting for </think>.  Guard against unbounded buffering.
            if (self.buf.items.len > MAX_BUF) self.flushAndForward();
        }
    };

    // ── VTable implementations ────────────────────────────────────────────────

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) anyerror![]const u8 {
        const self: *Qwen3LocalProvider = @ptrCast(@alignCast(ptr));
        var inner_prov = self.inner.provider();
        // Prepend /no_think pragma when configured.
        const msg: []const u8 = if (self.no_think) try prependNoThink(allocator, message) else message;
        defer if (self.no_think) allocator.free(msg);
        const raw = try inner_prov.chatWithSystem(allocator, system_prompt, msg, model, temperature);
        if (!self.shouldStrip()) return raw;
        errdefer allocator.free(raw);
        const stripped = try stripEmptyThinkBlock(allocator, raw);
        allocator.free(raw);
        return stripped;
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!ChatResponse {
        const self: *Qwen3LocalProvider = @ptrCast(@alignCast(ptr));
        var inner_prov = self.inner.provider();
        // Optionally prefix messages with /no_think pragma.
        const maybe_prefixed: ?[]root.ChatMessage = if (self.no_think)
            try buildPrefixedMessages(allocator, request.messages)
        else
            null;
        defer if (maybe_prefixed) |m| freePrefixedMessages(allocator, m);
        var req = request;
        if (maybe_prefixed) |m| req.messages = m;
        var response = try inner_prov.chat(allocator, req, model, temperature);
        if (self.shouldStrip()) {
            if (response.content) |raw| {
                errdefer allocator.free(raw);
                const stripped = try stripEmptyThinkBlock(allocator, raw);
                allocator.free(raw);
                response.content = stripped;
            }
        }
        return response;
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        // Qwen3 confabulates tool execution when the structured OpenAI tools
        // array is present.  Force XML <tool_call> format instead.
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "Qwen3 (local)";
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn streamChatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!StreamChatResult {
        const self: *Qwen3LocalProvider = @ptrCast(@alignCast(ptr));
        var inner_prov = self.inner.provider();
        // Optionally prefix messages with /no_think pragma.
        const maybe_prefixed: ?[]root.ChatMessage = if (self.no_think)
            try buildPrefixedMessages(allocator, request.messages)
        else
            null;
        defer if (maybe_prefixed) |m| freePrefixedMessages(allocator, m);
        var req = request;
        if (maybe_prefixed) |m| req.messages = m;
        if (self.shouldStrip()) {
            var filter = StreamThinkFilter.init(allocator, callback, callback_ctx);
            defer filter.deinit();
            var result = try inner_prov.streamChat(
                allocator, req, model, temperature,
                StreamThinkFilter.callback, &filter,
            );
            if (result.content) |raw| {
                errdefer allocator.free(raw);
                const stripped = try stripEmptyThinkBlock(allocator, raw);
                allocator.free(raw);
                result.content = stripped;
            }
            return result;
        }
        return inner_prov.streamChat(allocator, req, model, temperature, callback, callback_ctx);
    }

    fn supportsStreamingImpl(_: *anyopaque) bool {
        return true;
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
        .stream_chat = streamChatImpl,
        .supports_streaming = supportsStreamingImpl,
    };
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "Qwen3LocalProvider supportsNativeTools returns false" {
    var p = Qwen3LocalProvider.init(std.testing.allocator, "https://example.com/v1", "key", false, false);
    const prov = p.provider();
    try std.testing.expect(!prov.supportsNativeTools());
}

test "Qwen3LocalProvider getName" {
    var p = Qwen3LocalProvider.init(std.testing.allocator, "https://example.com/v1", "key", false, false);
    const prov = p.provider();
    try std.testing.expectEqualStrings("Qwen3 (local)", prov.getName());
}

test "prependNoThink prepends prefix" {
    const result = try Qwen3LocalProvider.prependNoThink(std.testing.allocator, "hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/no_think\nhello", result);
}

test "no_think false passes messages through unchanged" {
    const p = Qwen3LocalProvider.init(std.testing.allocator, "https://example.com/v1", null, false, false);
    try std.testing.expect(!p.no_think);
    try std.testing.expect(!p.shouldStrip());
}

test "no_think true is stored on provider" {
    const p = Qwen3LocalProvider.init(std.testing.allocator, "https://example.com/v1", null, true, false);
    try std.testing.expect(p.no_think);
    try std.testing.expect(p.shouldStrip());
}

test "strip_think_tags alone enables stripping without pragma" {
    const p = Qwen3LocalProvider.init(std.testing.allocator, "https://example.com/v1", null, false, true);
    try std.testing.expect(!p.no_think);
    try std.testing.expect(p.shouldStrip());
}

test "buildPrefixedMessages prefixes user messages only" {
    const allocator = std.testing.allocator;
    const msgs = [_]root.ChatMessage{
        .{ .role = .system, .content = "You are helpful." },
        .{ .role = .user, .content = "What is 2+2?" },
        .{ .role = .assistant, .content = "4" },
        .{ .role = .user, .content = "Are you sure?" },
    };
    const out = try Qwen3LocalProvider.buildPrefixedMessages(allocator, &msgs);
    defer Qwen3LocalProvider.freePrefixedMessages(allocator, out);

    try std.testing.expectEqualStrings("You are helpful.", out[0].content);
    try std.testing.expectEqualStrings("/no_think\nWhat is 2+2?", out[1].content);
    try std.testing.expectEqualStrings("4", out[2].content);
    try std.testing.expectEqualStrings("/no_think\nAre you sure?", out[3].content);
}

test "buildPrefixedMessages empty input" {
    const allocator = std.testing.allocator;
    const out = try Qwen3LocalProvider.buildPrefixedMessages(allocator, &.{});
    defer Qwen3LocalProvider.freePrefixedMessages(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "stripEmptyThinkBlock strips empty think block" {
    const allocator = std.testing.allocator;
    const input = "<think>\n\n</think>\n\nI'm just a bot.";
    const result = try Qwen3LocalProvider.stripEmptyThinkBlock(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("I'm just a bot.", result);
}

test "stripEmptyThinkBlock no-ops when no think block" {
    const allocator = std.testing.allocator;
    const input = "Hello there.";
    const result = try Qwen3LocalProvider.stripEmptyThinkBlock(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello there.", result);
}

test "stripEmptyThinkBlock does not strip non-empty think block" {
    const allocator = std.testing.allocator;
    const input = "<think>Some reasoning here.</think>\n\nAnswer.";
    const result = try Qwen3LocalProvider.stripEmptyThinkBlock(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "stripEmptyThinkBlock handles think block with only spaces" {
    const allocator = std.testing.allocator;
    const input = "<think>   \t  </think>Result.";
    const result = try Qwen3LocalProvider.stripEmptyThinkBlock(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Result.", result);
}

test "StreamThinkFilter strips empty think block from stream" {
    const allocator = std.testing.allocator;
    var collected: std.ArrayListUnmanaged(u8) = .empty;
    defer collected.deinit(allocator);

    const Ctx = struct {
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        fn cb(ctx_ptr: *anyopaque, chunk: StreamChunk) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (!chunk.is_final) ctx.buf.appendSlice(ctx.alloc, chunk.delta) catch {};
        }
    };
    var ctx = Ctx{ .buf = &collected, .alloc = allocator };

    var filter = Qwen3LocalProvider.StreamThinkFilter.init(allocator, Ctx.cb, &ctx);
    defer filter.deinit();

    // Simulate chunked stream: <think>\n\n</think>\n\nActual response.
    const chunks = [_][]const u8{ "<think>", "\n\n", "</think>", "\n\nActual response." };
    for (chunks) |c| {
        Qwen3LocalProvider.StreamThinkFilter.callback(&filter, StreamChunk.textDelta(c));
    }
    Qwen3LocalProvider.StreamThinkFilter.callback(&filter, StreamChunk.finalChunk());

    try std.testing.expectEqualStrings("Actual response.", collected.items);
}

test "StreamThinkFilter passes through text with no think block" {
    const allocator = std.testing.allocator;
    var collected: std.ArrayListUnmanaged(u8) = .empty;
    defer collected.deinit(allocator);

    const Ctx = struct {
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        fn cb(ctx_ptr: *anyopaque, chunk: StreamChunk) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (!chunk.is_final) ctx.buf.appendSlice(ctx.alloc, chunk.delta) catch {};
        }
    };
    var ctx = Ctx{ .buf = &collected, .alloc = allocator };

    var filter = Qwen3LocalProvider.StreamThinkFilter.init(allocator, Ctx.cb, &ctx);
    defer filter.deinit();

    Qwen3LocalProvider.StreamThinkFilter.callback(&filter, StreamChunk.textDelta("Hello world"));
    Qwen3LocalProvider.StreamThinkFilter.callback(&filter, StreamChunk.finalChunk());

    try std.testing.expectEqualStrings("Hello world", collected.items);
}

test "Qwen3LocalProvider no_think default is false in factory" {
    const factory = @import("factory.zig");
    var h = factory.ProviderHolder.fromConfig(
        std.testing.allocator,
        "qwen3-local:https://example.com/v1",
        "key",
        .{},
    );
    defer h.deinit();
    try std.testing.expect(h == .qwen3_local);
    try std.testing.expect(!h.qwen3_local.no_think);
    try std.testing.expect(!h.qwen3_local.strip_think_tags);
}

test "Qwen3LocalProvider no_think true from factory" {
    const factory = @import("factory.zig");
    var h = factory.ProviderHolder.fromConfig(
        std.testing.allocator,
        "qwen3-local:https://example.com/v1",
        "key",
        .{ .qwen3_no_think = true },
    );
    defer h.deinit();
    try std.testing.expect(h.qwen3_local.no_think);
}

test "Qwen3LocalProvider strip_think_tags from factory" {
    const factory = @import("factory.zig");
    var h = factory.ProviderHolder.fromConfig(
        std.testing.allocator,
        "qwen3-local:https://example.com/v1",
        "key",
        .{ .qwen3_strip_think_tags = true },
    );
    defer h.deinit();
    try std.testing.expect(!h.qwen3_local.no_think);
    try std.testing.expect(h.qwen3_local.strip_think_tags);
    try std.testing.expect(h.qwen3_local.shouldStrip());
}

test "ProviderHolder has qwen3_local field" {
    const factory = @import("factory.zig");
    try std.testing.expect(@hasField(factory.ProviderHolder, "qwen3_local"));
}

test "classifyProvider qwen3-local prefix" {
    const factory = @import("factory.zig");
    try std.testing.expect(
        factory.classifyProvider("qwen3-local:https://example.com/v1") == .qwen3_local_provider,
    );
}
