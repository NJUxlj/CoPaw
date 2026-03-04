---
name: deepwiki
description: "Use DeepWiki to quickly understand any GitHub repository's architecture, find implementation details in open-source projects, and research competitor designs. Use when users ask to understand a repo, research how another project works, compare implementations, explore dependency internals, or need AI-generated documentation for any GitHub repository."
---

# DeepWiki — AI Documentation for GitHub Repos

DeepWiki (`https://deepwiki.com`) by Cognition (Devin AI) auto-indexes GitHub repositories and generates interactive AI documentation including architecture overviews, module dependency graphs, and class/function docs.

## URL Format

```
https://deepwiki.com/{owner}/{repo}
```

To use: call WebFetch with the DeepWiki URL to retrieve the AI-generated documentation.

## Usage Scenarios

### 1. Understand a Competitor / Reference Project

```
Question: "How does OpenClaw's channel system work?"
→ WebFetch: https://deepwiki.com/openclaw/openclaw
→ Look for channels/ architecture docs
→ Compare with CoPaw's BaseChannel + ChannelManager pattern
```

### 2. Research a Dependency's Internals

```
Question: "How does AgentScope's ReActAgent implement the reasoning loop?"
→ WebFetch: https://deepwiki.com/modelscope/agentscope
→ Find ReActAgent implementation details
→ Understand what CoPawAgent inherits from the parent class
```

### 3. Evaluate a New Library

```
Question: "Should we use ChromaDB for the memory backend?"
→ WebFetch: https://deepwiki.com/chroma-core/chroma
→ Understand API design, embedding support, persistence model
→ Evaluate compatibility with CoPaw's MemoryManager (ReMe-AI)
```

## Quick Reference: CoPaw Ecosystem

### CoPaw Core Dependencies

| Repo | URL |
|------|-----|
| AgentScope | `deepwiki.com/modelscope/agentscope` |
| FastAPI | `deepwiki.com/fastapi/fastapi` |
| APScheduler | `deepwiki.com/agronholm/apscheduler` |
| Playwright | `deepwiki.com/microsoft/playwright` |
| Pydantic | `deepwiki.com/pydantic/pydantic` |
| MCP Servers | `deepwiki.com/modelcontextprotocol/servers` |
| MCP Python SDK | `deepwiki.com/modelcontextprotocol/python-sdk` |

### Personal Assistant Competitors

| Repo | URL |
|------|-----|
| OpenClaw | `deepwiki.com/openclaw/openclaw` |
| LobeHub | `deepwiki.com/lobehub/lobehub` |
| Dify | `deepwiki.com/langgenius/dify` |
| Open Interpreter | `deepwiki.com/OpenInterpreter/open-interpreter` |
| AutoGPT | `deepwiki.com/Significant-Gravitas/AutoGPT` |
| Claude Code | `deepwiki.com/anthropics/claude-code` |
| Anthropic Skills | `deepwiki.com/anthropics/skills` |

### Channel SDKs

| Repo | URL | CoPaw Channel |
|------|-----|--------------|
| dingtalk-stream | `deepwiki.com/open-dingtalk/dingtalk-stream` | DingTalk |
| lark-oapi | `deepwiki.com/larksuite/oapi-sdk-python` | Feishu |
| discord.py | `deepwiki.com/Rapptz/discord.py` | Discord |
| Ollama | `deepwiki.com/ollama/ollama` | Local models |

### Agent Frameworks

| Repo | URL |
|------|-----|
| LangChain | `deepwiki.com/langchain-ai/langchain` |
| LlamaIndex | `deepwiki.com/run-llama/llama_index` |
| CrewAI | `deepwiki.com/crewAIInc/crewAI` |

## Research Workflow

1. **Define the goal** — what specific question about what repo
2. **Fetch DeepWiki** — `WebFetch https://deepwiki.com/{owner}/{repo}`
3. **Navigate to relevant section** — architecture, specific module, or API docs
4. **Extract patterns** — identify design decisions and implementation approaches
5. **Adapt to CoPaw** — translate to Python, Pydantic config, async/await, 79-char lines
6. **Security check** — evaluate implications for a locally-running personal assistant

## Notes

- DeepWiki is read-only — it cannot modify repositories
- Index may lag behind latest commits
- Private repositories are not available
- Generated docs are AI analysis — verify critical details against source code
- Combine with `gh` CLI for dynamic info (PRs, issues, releases)
