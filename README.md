> **⚠️ PERSONAL FORK — AI-ASSISTED — USE AT YOUR OWN RISK**
>
> This is a personal fork of [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw) maintained for
> a specific private homelab setup. The changes here were developed with AI assistance and have not
> been reviewed or endorsed by the upstream maintainers.
> Dave IS NOT a Zig developer!  No insight into how some of this works.
>
> **What's different from upstream:**
> - Adds a `qwen3-local` provider type for self-hosted Qwen3 models via a vLLM/OpenAI-compatible endpoint (see [Qwen3 Local Provider](#qwen3-local-provider) below)
> - Two new per-model config flags: `no_think` and `strip_think_tags`
> - The [Configuration](#configuration) example below has been updated to show these additions
> - `Dockerfile` updated to use Alpine runtime (fixes musl/glibc mismatch with upstream's distroless image) + `root.pem` slot for a private CA cert
> - `docker-compose.yml` example included for running a named agent instance
>
> Branches: `qwen3-provider` (Qwen3 provider), `memory` (memory bug fix in progress).
> Upstream changes are tracked on the read-only `nullclaw-main-copy` branch.

---

<p align="center">
  <img src="nullclaw.png" alt="nullclaw" width="200" />
</p>

<h1 align="center">NullClaw</h1>

<p align="center">
  <strong>Null overhead. Null compromise. 100% Zig. 100% Agnostic.</strong><br>
  <strong>678 KB binary. ~1 MB RAM. Boots in <2 ms. Runs on anything with a CPU.</strong>
</p>

<p align="center">
  <a href="https://github.com/nullclaw/nullclaw/actions/workflows/ci.yml"><img src="https://github.com/nullclaw/nullclaw/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://nullclaw.github.io"><img src="https://img.shields.io/badge/docs-nullclaw.github.io-informational" alt="Documentation" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT" /></a>
</p>

The smallest fully autonomous AI assistant infrastructure — a static Zig binary that fits on any $5 board, boots in milliseconds, and requires nothing but libc.

```
678 KB binary · <2 ms startup · 2,843 tests · 22+ providers · 13 channels · Pluggable everything
```

### Features

- **Impossibly Small:** 678 KB static binary — no runtime, no VM, no framework overhead.
- **Near-Zero Memory:** ~1 MB peak RSS. Runs comfortably on the cheapest ARM SBCs and microcontrollers.
- **Instant Startup:** <2 ms on Apple Silicon, <8 ms on a 0.8 GHz edge core.
- **True Portability:** Single self-contained binary across ARM, x86, and RISC-V. Drop it anywhere, it just runs.
- **Feature-Complete:** 22+ providers, 11 channels, 18+ tools, hybrid vector+FTS5 memory, multi-layer sandbox, tunnels, hardware peripherals, MCP, subagents, streaming, voice — the full stack.

### Why nullclaw

- **Lean by default:** Zig compiles to a tiny static binary. No allocator overhead, no garbage collector, no runtime.
- **Secure by design:** pairing, strict sandboxing (landlock, firejail, bubblewrap, docker), explicit allowlists, workspace scoping, encrypted secrets.
- **Fully swappable:** core systems are vtable interfaces (providers, channels, tools, memory, tunnels, peripherals, observers, runtimes).
- **No lock-in:** OpenAI-compatible provider support + pluggable custom endpoints.

## Benchmark Snapshot

Local machine benchmark (macOS arm64, Feb 2026), normalized for 0.8 GHz edge hardware.

| | [OpenClaw](https://github.com/openclaw/openclaw) | [NanoBot](https://github.com/HKUDS/nanobot) | [PicoClaw](https://github.com/sipeed/picoclaw) | [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) | **[🦞 NullClaw](https://github.com/nullclaw/nullclaw)** |
|---|---|---|---|---|---|
| **Language** | TypeScript | Python | Go | Rust | **Zig** |
| **RAM** | > 1 GB | > 100 MB | < 10 MB | < 5 MB | **~1 MB** |
| **Startup (0.8 GHz)** | > 500 s | > 30 s | < 1 s | < 10 ms | **< 8 ms** |
| **Binary Size** | ~28 MB (dist) | N/A (Scripts) | ~8 MB | 3.4 MB | **678 KB** |
| **Tests** | — | — | — | 1,017 | **2,843** |
| **Source Files** | ~400+ | — | — | ~120 | **~110** |
| **Cost** | Mac Mini $599 | Linux SBC ~$50 | Linux Board $10 | Any $10 hardware | **Any $5 hardware** |

> Measured with `/usr/bin/time -l` on ReleaseSmall builds. nullclaw is a static binary with zero runtime dependencies.

Reproduce locally:

```bash
zig build -Doptimize=ReleaseSmall
ls -lh zig-out/bin/nullclaw

/usr/bin/time -l zig-out/bin/nullclaw --help
/usr/bin/time -l zig-out/bin/nullclaw status
```

## Quick Start

```bash
git clone https://github.com/nullclaw/nullclaw.git
cd nullclaw
zig build -Doptimize=ReleaseSmall

# Quick setup
nullclaw onboard --api-key sk-... --provider openrouter

# Or interactive wizard
nullclaw onboard --interactive

# Chat
nullclaw agent -m "Hello, nullclaw!"

# Interactive mode
nullclaw agent

# Start the gateway (webhook server)
nullclaw gateway                # default: 127.0.0.1:3000
nullclaw gateway --port 8080    # custom port

# Start full autonomous runtime
nullclaw daemon

# Check status
nullclaw status

# Run system diagnostics
nullclaw doctor

# Check channel health
nullclaw channel doctor

# Manage background service
nullclaw service install
nullclaw service status

# Migrate memory from OpenClaw
nullclaw migrate openclaw --dry-run
nullclaw migrate openclaw
```

> **Dev fallback (no global install):** prefix commands with `zig-out/bin/` (example: `zig-out/bin/nullclaw status`).

## Architecture

Every subsystem is a **vtable interface** — swap implementations with a config change, zero code changes.

| Subsystem | Interface | Ships with | Extend |
|-----------|-----------|------------|--------|
| **AI Models** | `Provider` | 22+ providers (OpenRouter, Anthropic, OpenAI, Ollama, Venice, Groq, Mistral, xAI, DeepSeek, Together, Fireworks, Perplexity, Cohere, Bedrock, etc.) | `custom:https://your-api.com` — any OpenAI-compatible API |
| **Channels** | `Channel` | CLI, Telegram, Discord, Slack, iMessage, Matrix, WhatsApp, Webhook, IRC, Lark/Feishu, DingTalk, QQ, MaixCam | Any messaging API |
| **Memory** | `Memory` | SQLite with hybrid search (FTS5 + vector cosine similarity), Markdown | Any persistence backend |
| **Tools** | `Tool` | shell, file_read, file_write, file_edit, memory_store, memory_recall, memory_forget, browser_open, screenshot, composio, http_request, hardware_info, hardware_memory, and more | Any capability |
| **Observability** | `Observer` | Noop, Log, File, Multi | Prometheus, OTel |
| **Runtime** | `RuntimeAdapter` | Native, Docker (sandboxed), WASM (wasmtime) | Any runtime |
| **Security** | `Sandbox` | Landlock, Firejail, Bubblewrap, Docker, auto-detect | Any sandbox backend |
| **Identity** | `IdentityConfig` | OpenClaw (markdown), AIEOS v1.1 (JSON) | Any identity format |
| **Tunnel** | `Tunnel` | None, Cloudflare, Tailscale, ngrok, Custom | Any tunnel binary |
| **Heartbeat** | Engine | HEARTBEAT.md periodic tasks | — |
| **Skills** | Loader | TOML manifests + SKILL.md instructions | Community skill packs |
| **Peripherals** | `Peripheral` | Serial, Arduino, Raspberry Pi GPIO, STM32/Nucleo | Any hardware interface |
| **Cron** | Scheduler | Cron expressions + one-shot timers with JSON persistence | — |

### Memory System

All custom, zero external dependencies:

| Layer | Implementation |
|-------|---------------|
| **Vector DB** | Embeddings stored as BLOB in SQLite, cosine similarity search |
| **Keyword Search** | FTS5 virtual tables with BM25 scoring |
| **Hybrid Merge** | Weighted merge (configurable vector/keyword weights) |
| **Embeddings** | `EmbeddingProvider` vtable — OpenAI, custom URL, or noop |
| **Hygiene** | Automatic archival + purge of stale memories |
| **Snapshots** | Export/import full memory state for migration |

```json
{
  "memory": {
    "backend": "sqlite",
    "auto_save": true,
    "embedding_provider": "openai",
    "vector_weight": 0.7,
    "keyword_weight": 0.3,
    "hygiene_enabled": true,
    "snapshot_enabled": false
  }
}
```

## Security

nullclaw enforces security at **every layer**.

| # | Item | Status | How |
|---|------|--------|-----|
| 1 | **Gateway not publicly exposed** | Done | Binds `127.0.0.1` by default. Refuses `0.0.0.0` without tunnel or explicit `allow_public_bind`. |
| 2 | **Pairing required** | Done | 6-digit one-time code on startup. Exchange via `POST /pair` for bearer token. |
| 3 | **Filesystem scoped** | Done | `workspace_only = true` by default. Null byte injection blocked. Symlink escape detection. |
| 4 | **Access via tunnel only** | Done | Gateway refuses public bind without active tunnel. Supports Tailscale, Cloudflare, ngrok, or custom. |
| 5 | **Sandbox isolation** | Done | Auto-detects best backend: Landlock, Firejail, Bubblewrap, or Docker. |
| 6 | **Encrypted secrets** | Done | API keys encrypted with ChaCha20-Poly1305 using local key file. |
| 7 | **Resource limits** | Done | Configurable memory, CPU, disk, and subprocess limits. |
| 8 | **Audit logging** | Done | Signed event trail with configurable retention. |

### Channel Allowlists

- Empty allowlist = **deny all inbound messages**
- `"*"` = **allow all** (explicit opt-in)
- Otherwise = exact-match allowlist

## Configuration

Config: `~/.nullclaw/config.json` (created by `onboard`)

> **OpenClaw compatible:** nullclaw uses the same config structure as [OpenClaw](https://github.com/openclaw/openclaw) (snake_case). Providers live under `models.providers`, the default model under `agents.defaults.model.primary`, and channels use `accounts` wrappers.

```json
{
  "default_provider": "openrouter",
  "default_temperature": 0.7,

  "models": {
    "providers": {
      "openrouter": { "api_key": "sk-or-..." },
      "groq": { "api_key": "gsk_..." },
      "anthropic": { "api_key": "sk-ant-...", "base_url": "https://api.anthropic.com" },

      "qwen3-local": {
        "base_url": "https://your-vllm-host:8000/v1",
        "models": [
          {
            "id": "YourOrg/Your-Qwen3-Model",
            "name": "Qwen3 (local)",
            "no_think": true,
            "strip_think_tags": true
          }
        ]
      }
    }
  },

  "agents": {
    "defaults": {
      "model": { "primary": "anthropic/claude-sonnet-4" },
      "heartbeat": { "every": "30m" }
    },
    "list": [
      { "id": "researcher", "model": { "primary": "anthropic/claude-opus-4" }, "system_prompt": "..." }
    ]
  },

  "channels": {
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "123:ABC",
          "allow_from": ["user1"],
          "reply_in_private": true,
          "proxy": "socks5://..."
        }
      }
    },
    "discord": {
      "accounts": {
        "main": {
          "token": "disc-token",
          "guild_id": "12345",
          "allow_from": ["user1"],
          "allow_bots": false
        }
      }
    },
    "irc": {
      "accounts": {
        "main": {
          "host": "irc.libera.chat",
          "port": 6697,
          "nick": "nullclaw",
          "channel": "#nullclaw",
          "tls": true,
          "allow_from": ["user1"]
        }
      }
    },
    "slack": {
      "accounts": {
        "main": {
          "bot_token": "xoxb-...",
          "app_token": "xapp-...",
          "allow_from": ["user1"]
        }
      }
    }
  },

  "tools": {
    "media": {
      "audio": {
        "enabled": true,
        "language": "ru",
        "models": [{ "provider": "groq", "model": "whisper-large-v3" }]
      }
    }
  },

  "mcp_servers": {
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem"] }
  },

  "memory": {
    "backend": "sqlite",
    "auto_save": true,
    "embedding_provider": "openai",
    "vector_weight": 0.7,
    "keyword_weight": 0.3
  },

  "gateway": {
    "port": 3000,
    "require_pairing": true,
    "allow_public_bind": false
  },

  "autonomy": {
    "level": "supervised",
    "workspace_only": true,
    "max_actions_per_hour": 20
  },

  "runtime": {
    "kind": "native",
    "docker": {
      "image": "alpine:3.20",
      "network": "none",
      "memory_limit_mb": 512,
      "read_only_rootfs": true
    }
  },


  "tunnel": { "provider": "none" },
  "secrets": { "encrypt": true },
  "identity": { "format": "openclaw" },

  "security": {
    "sandbox": { "backend": "auto" },
    "resources": { "max_memory_mb": 512, "max_cpu_percent": 80 },
    "audit": { "enabled": true, "retention_days": 90 }
  }
}
```

### Redacted/partial copy of Dave's configuration

Dave is using Proxmox VM/LXC etc. and certificates and LiteLLM etc. with firewalls/filtering/API-broker external to the VM.
LiteLLM presents public model names hence "RTX5090-Qwen3-30B-A3B-GPTQ-Int4".
Only simple system prompt shown here.

```json
{
  "default_provider": "qwen3-local:https://litellm.REDACTED.xarta.co.uk/v1",
  "default_temperature": 0.7,

  "models": {
    "providers": {
      "qwen3-local:https://litellm.REDACTED.xarta.co.uk/v1": {
        "api_key": "REDACTED",
        "models": [
          {
            "id": "MiniMax-M2.5",
            "name": "MiniMax M2.5"
          },
          {
            "id": "RTX5090-Qwen3-30B-A3B-GPTQ-Int4",
            "name": "Qwen3 30B A3B (local)",
            "no_think": true,
            "strip_think_tags": true
          }
        ]
      }
    }
  },

  "agents": {
    "defaults": {
      "model": {
        "primary": "RTX5090-Qwen3-30B-A3B-GPTQ-Int4"
      }
    },
    "list": [
      {
        "id": "testy",
        "default": true,
        "system_prompt": "You are a helpful assistant."
      }
    ]
  },

  "gateway": {
    "port": 3000,
    "host": "0.0.0.0",
    "allow_public_bind": true
  },

  "autonomy": {
    "level": "supervised",
    "workspace_only": true,
    "max_actions_per_hour": 20,
    "max_cost_per_day_cents": 500
  },

  "memory": {
    "backend": "sqlite",
    "auto_save": true,
    "embedding_provider": "custom:https://litellm.REDACTED.xarta.co.uk/v1",
    "embedding_model": "text-embedding-3-small",
    "embedding_dimensions": 1536
  },

  "tunnel": { "provider": "none" },
  "secrets": { "encrypt": true },
  "identity": { "format": "openclaw" },

  "channels": {
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "REDACTED:REDACTED",
          "allow_from": ["REDACTED"]
        }
      }
    }
  },

  "security": {
    "sandbox": { "backend": "auto" },
    "resources": { "max_memory_mb": 256, "max_cpu_percent": 80 },
    "audit": { "enabled": true, "retention_days": 90 }
  }
}
```

## Gateway API

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/health` | GET | None | Health check (always public) |
| `/pair` | POST | `X-Pairing-Code` header | Exchange one-time code for bearer token |
| `/webhook` | POST | `Authorization: Bearer <token>` | Send message: `{"message": "your prompt"}` |
| `/whatsapp` | GET | Query params | Meta webhook verification |
| `/whatsapp` | POST | None (Meta signature) | WhatsApp incoming message webhook |

## Commands

| Command | Description |
|---------|-------------|
| `onboard --api-key sk-... --provider openrouter` | Quick setup with API key and provider |
| `onboard --interactive` | Full interactive wizard |
| `onboard --channels-only` | Reconfigure channels/allowlists only |
| `agent -m "..."` | Single message mode |
| `agent` | Interactive chat mode |
| `gateway` | Start webhook server (default: `127.0.0.1:3000`) |
| `daemon` | Start long-running autonomous runtime |
| `service install\|start\|stop\|status\|uninstall` | Manage background service |
| `doctor` | Diagnose system health |
| `status` | Show full system status |
| `channel doctor` | Run channel health checks |
| `cron list\|add\|remove\|pause\|resume\|run` | Manage scheduled tasks |
| `skills list\|install\|remove\|info` | Manage skill packs |
| `hardware scan\|flash\|monitor` | Hardware device management |
| `models list\|info\|benchmark` | Model catalog |
| `migrate openclaw [--dry-run] [--source PATH]` | Import memory from OpenClaw workspace |

## Development

```bash
zig build                          # Dev build
zig build -Doptimize=ReleaseSmall  # Release build (678 KB)
zig build test --summary all       # 2,843 tests
```

### Project Stats

```
Language:     Zig 0.15
Source files: ~110
Lines of code: ~45,000
Tests:        2,843
Binary:       678 KB (ReleaseSmall)
Peak RSS:     ~1 MB
Startup:      <2 ms (Apple Silicon)
Dependencies: 0 (besides libc + optional SQLite)
```

### Source Layout

```
src/
  main.zig              CLI entry point + argument parsing
  root.zig              Module hierarchy (public API)
  config.zig            JSON config loader + 30 sub-config structs
  agent.zig             Agent loop, auto-compaction, tool dispatch
  daemon.zig            Daemon supervisor with exponential backoff
  gateway.zig           HTTP gateway (rate limiting, idempotency, pairing)
  channels/             11 channel implementations (telegram, discord, slack, ...)
  providers/            22+ AI provider implementations
  memory/               SQLite backend, embeddings, vector search, hygiene, snapshots
  tools/                18 tool implementations
  security/             Secrets (ChaCha20), sandbox backends (landlock, firejail, ...)
  cron.zig              Cron scheduler with JSON persistence
  health.zig            Component health registry
  tunnel.zig            Tunnel vtable (cloudflare, ngrok, tailscale, custom)
  peripherals.zig       Hardware peripheral vtable (serial, Arduino, RPi, Nucleo)
  runtime.zig           Runtime vtable (native, docker, WASM)
  skillforge.zig        Skill discovery (GitHub), evaluation, integration
  ...
```

## Versioning

nullclaw uses **CalVer** (`YYYY.M.D`) for releases — e.g. `v2026.2.20`.

- **Tag format:** `vYYYY.M.D` (one release per day max; patch suffix `vYYYY.M.D.N` if needed)
- **No stability guarantees yet** — the project is pre-1.0, config and CLI may change between releases
- **`nullclaw --version`** prints the current version

## Qwen3 Local Provider

> **Fork addition** — not in upstream nullclaw.

The `qwen3-local` provider wraps the standard OpenAI-compatible provider with Qwen3-specific
behaviour. Qwen3 models support an explicit "thinking" mode that emits `<think>...</think>` blocks
before the actual response. Depending on your use case you may want to suppress this entirely or
strip the tags from the output.

### Why this exists

When running a local Qwen3 model (e.g. via [vLLM](https://github.com/vllm-project/vllm)) behind
an OpenAI-compatible endpoint, the model always has thinking enabled by default. For conversational
or channel-facing agents the think blocks add latency and noise. This provider lets you disable
them at the config level without touching any code.

### How it works

| Flag | Effect |
|---|---|
| `no_think: true` | Prepends `/no_think\n` to every user message, asking the model to skip thinking mode entirely |
| `strip_think_tags: true` | Strips any leading `<think>...</think>` block (including empty ones) from the response before it reaches the agent or channel. Works on both streaming and non-streaming responses |
| Both `true` | `/no_think` is sent **and** any residual think block is stripped — belt and braces |

Both flags default to `false`. Set them per model entry in config (see [Configuration](#configuration)).

### Provider key format

The provider type is identified by the key prefix `qwen3-local:` followed by the base URL:

```json
"qwen3-local": {
  "base_url": "http://your-vllm-host:8000/v1"
}
```

See the full example in [Configuration](#configuration).

---

## Contributing

Implement a vtable interface, submit a PR:

- New `Provider` -> `src/providers/`
- New `Channel` -> `src/channels/`
- New `Tool` -> `src/tools/`
- New `Memory` backend -> `src/memory/`
- New `Tunnel` -> `src/tunnel.zig`
- New `Sandbox` backend -> `src/security/`
- New `Peripheral` -> `src/peripherals.zig`
- New `Skill` -> `~/.nullclaw/workspace/skills/<name>/`

## Disclaimer

nullclaw is a pure open-source software project. It has **no token, no cryptocurrency, no blockchain component, and no financial instrument** of any kind. This project is not affiliated with any token or financial product.

## License

MIT — see [LICENSE](LICENSE)

---

**nullclaw** — Null overhead. Null compromise. Deploy anywhere. Swap anything.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=nullclaw/nullclaw&type=date&legend=top-left)](https://www.star-history.com/#nullclaw/nullclaw&type=date&legend=top-left)
