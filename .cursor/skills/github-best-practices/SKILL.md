---
name: github-best-practices
description: "Search and compare best practices from similar personal AI assistant projects on GitHub. Use when users ask about reference implementations, how OpenClaw or other projects solve a problem, industry patterns, competitor analysis, or need to evaluate approaches from open-source projects for features like channels, skills, memory, scheduling, or MCP integration."
---

# GitHub Best Practices Search

Research best practices from the open-source personal AI assistant ecosystem and adapt them to CoPaw's architecture.

## Competitor Knowledge Base

### Core Comparables

| Project | Stack | Repo | Strengths |
|---------|-------|------|-----------|
| **OpenClaw** | Node.js/TS | `openclaw/openclaw` | 22+ channels, Gateway WS, Voice, Canvas |
| **Open Interpreter** | Python | `OpenInterpreter/open-interpreter` | Local code execution, sandboxing |
| **LobeHub** | Next.js/TS | `lobehub/lobehub` | Multi-agent collaboration, polished UI |
| **Dify** | Python + Next.js | `langgenius/dify` | Visual workflow builder, RAG pipeline |
| **AutoGPT** | Python | `Significant-Gravitas/AutoGPT` | Autonomous agents, task planning |
| **n8n** | Node.js/TS | `n8n-io/n8n` | Workflow automation, 400+ integrations |

### CoPaw vs OpenClaw Architecture Comparison

| Aspect | CoPaw | OpenClaw |
|--------|-------|---------|
| Language | Python backend + React frontend | TypeScript full-stack |
| Agent framework | AgentScope ReActAgent | Pi agent (custom RPC) |
| Channel arch | BaseChannel + ChannelManager queue | Gateway WebSocket control plane |
| Skills format | SKILL.md (Markdown instructions) | SKILL.md (similar format) |
| Workspace | `~/.copaw/` | `~/.openclaw/workspace/` |
| Persona files | `AGENTS.md`, `SOUL.md`, `PROFILE.md` | `AGENTS.md`, `SOUL.md`, `TOOLS.md` |
| Config | `config.json` (Pydantic) | `openclaw.json` (JS object) |
| Model mgmt | Provider registry + local models | OAuth subscriptions + failover |
| Scheduling | APScheduler | Built-in cron |
| Browser | Playwright | CDP (Chrome DevTools Protocol) |
| MCP | MCPClientManager (stdio) | Via Skills extension |
| Security | Local trust model | DM pairing + sandbox mode |
| Voice | None | Voice Wake + Talk Mode |
| Mobile | None | iOS/Android nodes |
| Deploy | Docker + supervisord | Node.js daemon + Docker |

### Reference Projects by Domain

For detailed reference implementations, use DeepWiki (`https://deepwiki.com/{owner}/{repo}`) to explore any repository.

**Channels**: OpenClaw (22+ channels), Wechaty (WeChat), python-telegram-bot, discord.py, slack-sdk, lark-oapi

**Agent frameworks**: AgentScope, LangChain, LlamaIndex, CrewAI

**Memory**: ChromaDB, Pinecone, MemGPT, LangChain ConversationSummaryMemory

**Skills/Plugins**: OpenClaw Skills, ClawHub, Anthropic Skills (`anthropics/skills`), Dify Workflows

**Local models**: llama.cpp, Ollama, MLX, vLLM

**MCP protocol**: `modelcontextprotocol/servers`, `modelcontextprotocol/python-sdk`

## Evaluation Criteria

When evaluating a reference implementation for CoPaw adoption:

| Criterion | Question |
|-----------|----------|
| **Architecture fit** | Can it integrate into CoPaw's layered architecture without introducing new paradigms? |
| **Dependency weight** | Does it add heavy dependencies? (CoPaw prefers lightweight) |
| **Async compat** | Is it compatible with CoPaw's async/await model? |
| **Config pattern** | Can it be managed via Pydantic Config? |
| **Extension model** | Does it follow BaseChannel/BaseTool interface patterns? |
| **Single-user fit** | Is it appropriate for a single-user local assistant (not distributed/multi-tenant)? |

## Research Workflow

1. Clarify the feature requirement and context
2. Identify reference projects from the knowledge base above
3. Use DeepWiki (`https://deepwiki.com/{owner}/{repo}`) to quickly understand the repo architecture
4. Locate the specific implementation (module/file level)
5. Extract design patterns and evaluate against CoPaw criteria
6. Adapt to CoPaw conventions (Python 79-char lines, double quotes, Pydantic models, async/await)
7. Assess security implications (local-running assistants are more sensitive to tool permissions)
