const std = @import("std");
const root = @import("root.zig");
const Provider = root.Provider;
const anthropic = @import("anthropic.zig");
const openai = @import("openai.zig");
const ollama = @import("ollama.zig");
const gemini = @import("gemini.zig");
const openrouter = @import("openrouter.zig");
const compatible = @import("compatible.zig");
const claude_cli = @import("claude_cli.zig");
const codex_cli = @import("codex_cli.zig");
const openai_codex = @import("openai_codex.zig");
const qwen3_local = @import("qwen3_local.zig");

pub const ProviderKind = enum {
    anthropic_provider,
    openai_provider,
    openrouter_provider,
    ollama_provider,
    gemini_provider,
    compatible_provider,
    claude_cli_provider,
    codex_cli_provider,
    openai_codex_provider,
    qwen3_local_provider,
    unknown,
};

/// Determine which provider to create from a name string.
pub fn classifyProvider(name: []const u8) ProviderKind {
    const provider_map = std.StaticStringMap(ProviderKind).initComptime(.{
        .{ "anthropic", .anthropic_provider },
        .{ "openai", .openai_provider },
        .{ "openrouter", .openrouter_provider },
        .{ "ollama", .ollama_provider },
        .{ "gemini", .gemini_provider },
        .{ "google", .gemini_provider },
        .{ "google-gemini", .gemini_provider },
        .{ "claude-cli", .claude_cli_provider },
        .{ "codex-cli", .codex_cli_provider },
        .{ "openai-codex", .openai_codex_provider },
        // OpenAI-compatible providers
        .{ "venice", .compatible_provider },
        .{ "vercel", .compatible_provider },
        .{ "vercel-ai", .compatible_provider },
        .{ "cloudflare", .compatible_provider },
        .{ "cloudflare-ai", .compatible_provider },
        .{ "moonshot", .compatible_provider },
        .{ "kimi", .compatible_provider },
        .{ "synthetic", .compatible_provider },
        .{ "opencode", .compatible_provider },
        .{ "opencode-zen", .compatible_provider },
        .{ "zai", .compatible_provider },
        .{ "z.ai", .compatible_provider },
        .{ "glm", .compatible_provider },
        .{ "zhipu", .compatible_provider },
        .{ "minimax", .compatible_provider },
        .{ "bedrock", .compatible_provider },
        .{ "aws-bedrock", .compatible_provider },
        .{ "qianfan", .compatible_provider },
        .{ "baidu", .compatible_provider },
        .{ "qwen", .compatible_provider },
        .{ "dashscope", .compatible_provider },
        .{ "qwen-intl", .compatible_provider },
        .{ "dashscope-intl", .compatible_provider },
        .{ "qwen-us", .compatible_provider },
        .{ "dashscope-us", .compatible_provider },
        .{ "groq", .compatible_provider },
        .{ "mistral", .compatible_provider },
        .{ "xai", .compatible_provider },
        .{ "grok", .compatible_provider },
        .{ "deepseek", .compatible_provider },
        .{ "together", .compatible_provider },
        .{ "together-ai", .compatible_provider },
        .{ "fireworks", .compatible_provider },
        .{ "fireworks-ai", .compatible_provider },
        .{ "perplexity", .compatible_provider },
        .{ "cohere", .compatible_provider },
        .{ "copilot", .compatible_provider },
        .{ "github-copilot", .compatible_provider },
        .{ "lmstudio", .compatible_provider },
        .{ "lm-studio", .compatible_provider },
        .{ "nvidia", .compatible_provider },
        .{ "nvidia-nim", .compatible_provider },
        .{ "build.nvidia.com", .compatible_provider },
        .{ "astrai", .compatible_provider },
        .{ "poe", .compatible_provider },
    });

    if (provider_map.get(name)) |kind| return kind;

    // custom: prefix
    if (std.mem.startsWith(u8, name, "custom:")) return .compatible_provider;

    // anthropic-custom: prefix
    if (std.mem.startsWith(u8, name, "anthropic-custom:")) return .anthropic_provider;

    // qwen3-local: prefix — local Qwen3 model via OpenAI-compatible endpoint
    if (std.mem.startsWith(u8, name, "qwen3-local:")) return .qwen3_local_provider;

    return .unknown;
}

/// Auto-detect provider kind from an API key prefix.
pub fn detectProviderByApiKey(key: []const u8) ProviderKind {
    if (key.len < 3) return .unknown;
    if (std.mem.startsWith(u8, key, "sk-or-")) return .openrouter_provider;
    if (std.mem.startsWith(u8, key, "sk-ant-")) return .anthropic_provider;
    if (std.mem.startsWith(u8, key, "sk-")) return .openai_provider;
    if (std.mem.startsWith(u8, key, "gsk_")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "xai-")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "pplx-")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "AKIA")) return .compatible_provider;
    if (std.mem.startsWith(u8, key, "AIza")) return .gemini_provider;
    return .unknown;
}

/// Get the base URL for an OpenAI-compatible provider by name.
pub fn compatibleProviderUrl(name: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "venice", "https://api.venice.ai" },
        .{ "vercel", "https://api.vercel.ai" },
        .{ "vercel-ai", "https://api.vercel.ai" },
        .{ "cloudflare", "https://gateway.ai.cloudflare.com/v1" },
        .{ "cloudflare-ai", "https://gateway.ai.cloudflare.com/v1" },
        .{ "moonshot", "https://api.moonshot.cn" },
        .{ "kimi", "https://api.moonshot.cn" },
        .{ "synthetic", "https://api.synthetic.com" },
        .{ "opencode", "https://api.opencode.ai" },
        .{ "opencode-zen", "https://api.opencode.ai" },
        .{ "zai", "https://api.z.ai/api/coding/paas/v4" },
        .{ "z.ai", "https://api.z.ai/api/coding/paas/v4" },
        .{ "glm", "https://api.z.ai/api/paas/v4" },
        .{ "zhipu", "https://api.z.ai/api/paas/v4" },
        .{ "minimax", "https://api.minimaxi.com/v1" },
        .{ "bedrock", "https://bedrock-runtime.us-east-1.amazonaws.com" },
        .{ "aws-bedrock", "https://bedrock-runtime.us-east-1.amazonaws.com" },
        .{ "qianfan", "https://aip.baidubce.com" },
        .{ "baidu", "https://aip.baidubce.com" },
        .{ "qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1" },
        .{ "dashscope", "https://dashscope.aliyuncs.com/compatible-mode/v1" },
        .{ "qwen-intl", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" },
        .{ "dashscope-intl", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" },
        .{ "qwen-us", "https://dashscope-us.aliyuncs.com/compatible-mode/v1" },
        .{ "dashscope-us", "https://dashscope-us.aliyuncs.com/compatible-mode/v1" },
        .{ "groq", "https://api.groq.com/openai" },
        .{ "mistral", "https://api.mistral.ai" },
        .{ "xai", "https://api.x.ai" },
        .{ "grok", "https://api.x.ai" },
        .{ "deepseek", "https://api.deepseek.com" },
        .{ "together", "https://api.together.xyz" },
        .{ "together-ai", "https://api.together.xyz" },
        .{ "fireworks", "https://api.fireworks.ai/inference/v1" },
        .{ "fireworks-ai", "https://api.fireworks.ai/inference/v1" },
        .{ "perplexity", "https://api.perplexity.ai" },
        .{ "cohere", "https://api.cohere.com/compatibility" },
        .{ "copilot", "https://api.githubcopilot.com" },
        .{ "github-copilot", "https://api.githubcopilot.com" },
        .{ "lmstudio", "http://localhost:1234/v1" },
        .{ "lm-studio", "http://localhost:1234/v1" },
        .{ "nvidia", "https://integrate.api.nvidia.com/v1" },
        .{ "nvidia-nim", "https://integrate.api.nvidia.com/v1" },
        .{ "build.nvidia.com", "https://integrate.api.nvidia.com/v1" },
        .{ "astrai", "https://as-trai.com/v1" },
        .{ "poe", "https://api.poe.com/v1" },
    });
    return map.get(name);
}

/// Get the display name for an OpenAI-compatible provider.
pub fn compatibleProviderDisplayName(name: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "venice", "Venice" },
        .{ "vercel", "Vercel AI Gateway" },
        .{ "vercel-ai", "Vercel AI Gateway" },
        .{ "cloudflare", "Cloudflare AI Gateway" },
        .{ "cloudflare-ai", "Cloudflare AI Gateway" },
        .{ "moonshot", "Moonshot" },
        .{ "kimi", "Moonshot" },
        .{ "synthetic", "Synthetic" },
        .{ "opencode", "OpenCode Zen" },
        .{ "opencode-zen", "OpenCode Zen" },
        .{ "zai", "Z.AI" },
        .{ "z.ai", "Z.AI" },
        .{ "glm", "GLM" },
        .{ "zhipu", "GLM" },
        .{ "minimax", "MiniMax" },
        .{ "bedrock", "Amazon Bedrock" },
        .{ "aws-bedrock", "Amazon Bedrock" },
        .{ "qianfan", "Qianfan" },
        .{ "baidu", "Qianfan" },
        .{ "qwen", "Qwen" },
        .{ "dashscope", "Qwen" },
        .{ "qwen-intl", "Qwen" },
        .{ "dashscope-intl", "Qwen" },
        .{ "qwen-us", "Qwen" },
        .{ "dashscope-us", "Qwen" },
        .{ "groq", "Groq" },
        .{ "mistral", "Mistral" },
        .{ "xai", "xAI" },
        .{ "grok", "xAI" },
        .{ "deepseek", "DeepSeek" },
        .{ "together", "Together AI" },
        .{ "together-ai", "Together AI" },
        .{ "fireworks", "Fireworks AI" },
        .{ "fireworks-ai", "Fireworks AI" },
        .{ "perplexity", "Perplexity" },
        .{ "cohere", "Cohere" },
        .{ "copilot", "GitHub Copilot" },
        .{ "github-copilot", "GitHub Copilot" },
        .{ "lmstudio", "LM Studio" },
        .{ "lm-studio", "LM Studio" },
        .{ "nvidia", "NVIDIA NIM" },
        .{ "nvidia-nim", "NVIDIA NIM" },
        .{ "build.nvidia.com", "NVIDIA NIM" },
        .{ "astrai", "Astrai" },
        .{ "poe", "Poe" },
    });
    return map.get(name) orelse "Custom";
}

/// Tagged union so the concrete provider struct lives alongside the caller
/// (stack or heap) and its vtable pointer remains stable.
pub const ProviderHolder = union(enum) {
    openrouter: openrouter.OpenRouterProvider,
    anthropic: anthropic.AnthropicProvider,
    openai: openai.OpenAiProvider,
    gemini: gemini.GeminiProvider,
    ollama: ollama.OllamaProvider,
    compatible: compatible.OpenAiCompatibleProvider,
    claude_cli: claude_cli.ClaudeCliProvider,
    codex_cli: codex_cli.CodexCliProvider,
    openai_codex: openai_codex.OpenAiCodexProvider,
    qwen3_local: qwen3_local.Qwen3LocalProvider,

    /// Obtain the vtable-based Provider interface from whichever variant is active.
    pub fn provider(self: *ProviderHolder) Provider {
        return switch (self.*) {
            .openrouter => |*p| p.provider(),
            .anthropic => |*p| p.provider(),
            .openai => |*p| p.provider(),
            .gemini => |*p| p.provider(),
            .ollama => |*p| p.provider(),
            .compatible => |*p| p.provider(),
            .claude_cli => |*p| p.provider(),
            .codex_cli => |*p| p.provider(),
            .openai_codex => |*p| p.provider(),
            .qwen3_local => |*p| p.provider(),
        };
    }

    /// Release any resources owned by the active provider variant.
    pub fn deinit(self: *ProviderHolder) void {
        self.provider().deinit();
    }

    /// True when the active variant is a Qwen3 local provider.
    pub fn isQwen3Local(self: *const ProviderHolder) bool {
        return self.* == .qwen3_local;
    }

    /// Create a ProviderHolder from a provider name string and optional API key.
    /// Uses `classifyProvider` to route to the correct concrete provider.
    ///
    /// `opts.qwen3_no_think` / `opts.qwen3_strip_think_tags` are passed to
    /// `Qwen3LocalProvider`.  Call sites should supply the matching
    /// `cfg.defaultModelNoThink()` / `cfg.defaultModelStripThinkTags()` values
    /// so these come from the model entry in config.json.
    pub fn fromConfig(
        allocator: std.mem.Allocator,
        provider_name: []const u8,
        api_key: ?[]const u8,
        opts: struct { qwen3_no_think: bool = false, qwen3_strip_think_tags: bool = false },
    ) ProviderHolder {
        const kind = classifyProvider(provider_name);
        return switch (kind) {
            .anthropic_provider => .{ .anthropic = anthropic.AnthropicProvider.init(
                allocator,
                api_key,
                if (std.mem.startsWith(u8, provider_name, "anthropic-custom:"))
                    provider_name["anthropic-custom:".len..]
                else
                    null,
            ) },
            .openai_provider => .{ .openai = openai.OpenAiProvider.init(allocator, api_key) },
            .gemini_provider => .{ .gemini = gemini.GeminiProvider.init(allocator, api_key) },
            .ollama_provider => .{ .ollama = ollama.OllamaProvider.init(allocator, null) },
            .openrouter_provider => .{ .openrouter = openrouter.OpenRouterProvider.init(allocator, api_key) },
            .compatible_provider => .{ .compatible = compatible.OpenAiCompatibleProvider.init(
                allocator,
                provider_name,
                if (std.mem.startsWith(u8, provider_name, "custom:"))
                    provider_name["custom:".len..]
                else
                    compatibleProviderUrl(provider_name) orelse "https://openrouter.ai/api/v1",
                api_key,
                .bearer,
            ) },
            .qwen3_local_provider => .{ .qwen3_local = qwen3_local.Qwen3LocalProvider.init(
                allocator,
                // Strip the "qwen3-local:" prefix to get the base URL.
                if (std.mem.startsWith(u8, provider_name, "qwen3-local:"))
                    provider_name["qwen3-local:".len..]
                else
                    "http://localhost:8000/v1",
                api_key,
                opts.qwen3_no_think,
                opts.qwen3_strip_think_tags,
            ) },
            .claude_cli_provider => if (claude_cli.ClaudeCliProvider.init(allocator, null)) |p|
                .{ .claude_cli = p }
            else |_|
                .{ .openrouter = openrouter.OpenRouterProvider.init(allocator, api_key) },
            .codex_cli_provider => if (codex_cli.CodexCliProvider.init(allocator, null)) |p|
                .{ .codex_cli = p }
            else |_|
                .{ .openrouter = openrouter.OpenRouterProvider.init(allocator, api_key) },
            .openai_codex_provider => .{ .openai_codex = openai_codex.OpenAiCodexProvider.init(allocator, null) },
            .unknown => .{ .openrouter = openrouter.OpenRouterProvider.init(allocator, api_key) },
        };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "classifyProvider identifies known providers" {
    try std.testing.expect(classifyProvider("anthropic") == .anthropic_provider);
    try std.testing.expect(classifyProvider("openai") == .openai_provider);
    try std.testing.expect(classifyProvider("openrouter") == .openrouter_provider);
    try std.testing.expect(classifyProvider("ollama") == .ollama_provider);
    try std.testing.expect(classifyProvider("gemini") == .gemini_provider);
    try std.testing.expect(classifyProvider("google") == .gemini_provider);
    try std.testing.expect(classifyProvider("groq") == .compatible_provider);
    try std.testing.expect(classifyProvider("mistral") == .compatible_provider);
    try std.testing.expect(classifyProvider("deepseek") == .compatible_provider);
    try std.testing.expect(classifyProvider("venice") == .compatible_provider);
    try std.testing.expect(classifyProvider("poe") == .compatible_provider);
    try std.testing.expect(classifyProvider("custom:https://example.com") == .compatible_provider);
    try std.testing.expect(classifyProvider("openai-codex") == .openai_codex_provider);
    try std.testing.expect(classifyProvider("nonexistent") == .unknown);
}

test "compatibleProviderUrl returns correct URLs" {
    try std.testing.expectEqualStrings("https://api.venice.ai", compatibleProviderUrl("venice").?);
    try std.testing.expectEqualStrings("https://api.groq.com/openai", compatibleProviderUrl("groq").?);
    try std.testing.expectEqualStrings("https://api.deepseek.com", compatibleProviderUrl("deepseek").?);
    try std.testing.expectEqualStrings("https://api.poe.com/v1", compatibleProviderUrl("poe").?);
    try std.testing.expect(compatibleProviderUrl("nonexistent") == null);
}

test "nvidia resolves to correct URL" {
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1", compatibleProviderUrl("nvidia").?);
}

test "lm-studio resolves to localhost:1234" {
    try std.testing.expectEqualStrings("http://localhost:1234/v1", compatibleProviderUrl("lm-studio").?);
}

test "astrai resolves to astrai API URL" {
    try std.testing.expectEqualStrings("https://as-trai.com/v1", compatibleProviderUrl("astrai").?);
}

test "anthropic-custom prefix classifies as anthropic provider" {
    try std.testing.expect(classifyProvider("anthropic-custom:https://my-api.example.com") == .anthropic_provider);
}

test "new providers display names" {
    try std.testing.expectEqualStrings("NVIDIA NIM", compatibleProviderDisplayName("nvidia"));
    try std.testing.expectEqualStrings("NVIDIA NIM", compatibleProviderDisplayName("nvidia-nim"));
    try std.testing.expectEqualStrings("NVIDIA NIM", compatibleProviderDisplayName("build.nvidia.com"));
    try std.testing.expectEqualStrings("LM Studio", compatibleProviderDisplayName("lmstudio"));
    try std.testing.expectEqualStrings("LM Studio", compatibleProviderDisplayName("lm-studio"));
    try std.testing.expectEqualStrings("Astrai", compatibleProviderDisplayName("astrai"));
}

test "new providers classify as compatible" {
    try std.testing.expect(classifyProvider("nvidia") == .compatible_provider);
    try std.testing.expect(classifyProvider("nvidia-nim") == .compatible_provider);
    try std.testing.expect(classifyProvider("build.nvidia.com") == .compatible_provider);
    try std.testing.expect(classifyProvider("lmstudio") == .compatible_provider);
    try std.testing.expect(classifyProvider("lm-studio") == .compatible_provider);
    try std.testing.expect(classifyProvider("astrai") == .compatible_provider);
}

test "detectProviderByApiKey openrouter" {
    try std.testing.expect(detectProviderByApiKey("sk-or-v1-abc123") == .openrouter_provider);
}

test "detectProviderByApiKey anthropic" {
    try std.testing.expect(detectProviderByApiKey("sk-ant-api03-abc123") == .anthropic_provider);
}

test "detectProviderByApiKey openai" {
    try std.testing.expect(detectProviderByApiKey("sk-proj-abc123") == .openai_provider);
}

test "detectProviderByApiKey groq" {
    try std.testing.expect(detectProviderByApiKey("gsk_abc123def456") == .compatible_provider);
}

test "detectProviderByApiKey xai" {
    try std.testing.expect(detectProviderByApiKey("xai-abc123") == .compatible_provider);
}

test "detectProviderByApiKey perplexity" {
    try std.testing.expect(detectProviderByApiKey("pplx-abc123") == .compatible_provider);
}

test "detectProviderByApiKey aws" {
    try std.testing.expect(detectProviderByApiKey("AKIAIOSFODNN7EXAMPLE") == .compatible_provider);
}

test "detectProviderByApiKey gemini" {
    try std.testing.expect(detectProviderByApiKey("AIzaSyAbc123") == .gemini_provider);
}

test "detectProviderByApiKey unknown" {
    try std.testing.expect(detectProviderByApiKey("random-key") == .unknown);
}

test "detectProviderByApiKey short key" {
    try std.testing.expect(detectProviderByApiKey("ab") == .unknown);
}

test "ProviderHolder tagged union has all expected fields" {
    try std.testing.expect(@hasField(ProviderHolder, "openrouter"));
    try std.testing.expect(@hasField(ProviderHolder, "anthropic"));
    try std.testing.expect(@hasField(ProviderHolder, "openai"));
    try std.testing.expect(@hasField(ProviderHolder, "gemini"));
    try std.testing.expect(@hasField(ProviderHolder, "ollama"));
    try std.testing.expect(@hasField(ProviderHolder, "compatible"));
    try std.testing.expect(@hasField(ProviderHolder, "claude_cli"));
    try std.testing.expect(@hasField(ProviderHolder, "codex_cli"));
    try std.testing.expect(@hasField(ProviderHolder, "openai_codex"));
}

test "ProviderHolder.fromConfig routes to correct variant" {
    const alloc = std.testing.allocator;
    // anthropic
    var h1 = ProviderHolder.fromConfig(alloc, "anthropic", "sk-test", .{});
    defer h1.deinit();
    try std.testing.expect(h1 == .anthropic);
    // openai
    var h2 = ProviderHolder.fromConfig(alloc, "openai", "sk-test", .{});
    defer h2.deinit();
    try std.testing.expect(h2 == .openai);
    // gemini
    var h3 = ProviderHolder.fromConfig(alloc, "gemini", "key", .{});
    defer h3.deinit();
    try std.testing.expect(h3 == .gemini);
    // ollama
    var h4 = ProviderHolder.fromConfig(alloc, "ollama", null, .{});
    defer h4.deinit();
    try std.testing.expect(h4 == .ollama);
    // openrouter
    var h5 = ProviderHolder.fromConfig(alloc, "openrouter", "sk-or-test", .{});
    defer h5.deinit();
    try std.testing.expect(h5 == .openrouter);
    // compatible (groq)
    var h6 = ProviderHolder.fromConfig(alloc, "groq", "gsk_test", .{});
    defer h6.deinit();
    try std.testing.expect(h6 == .compatible);
    // openai-codex
    var h7 = ProviderHolder.fromConfig(alloc, "openai-codex", null, .{});
    defer h7.deinit();
    try std.testing.expect(h7 == .openai_codex);
    // unknown falls back to openrouter
    var h8 = ProviderHolder.fromConfig(alloc, "nonexistent", "key", .{});
    defer h8.deinit();
    try std.testing.expect(h8 == .openrouter);
    // anthropic-custom prefix
    var h9 = ProviderHolder.fromConfig(alloc, "anthropic-custom:https://my-api.example.com", "sk-test", .{});
    defer h9.deinit();
    try std.testing.expect(h9 == .anthropic);
}
