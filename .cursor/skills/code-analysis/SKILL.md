---
name: code-analysis
description: "Analyze CoPaw codebase structure, trace call chains, understand module responsibilities, locate performance bottlenecks, and map data flows. Use when users ask to analyze code, understand architecture, trace dependencies, inspect data flows, or profile module responsibilities in this personal AI assistant project."
---

# Code Analysis for CoPaw

## Layered Analysis Method

Always locate the code in the correct architectural layer first:

```
CLI (cli/)               → User-facing commands (click)
App (app/)               → FastAPI + component orchestration
  ├── Channels (channels/) → Message receive/send
  ├── Runner (runner/)     → Agent execution + session mgmt
  ├── Crons (crons/)       → APScheduler scheduled tasks
  ├── Routers (routers/)   → REST API endpoints
  └── MCP (mcp/)           → External tool integration
Agent (agents/)            → Core intelligence
  ├── react_agent.py       → ReAct loop (CoPawAgent)
  ├── tools/               → Built-in tool functions
  ├── skills/              → SKILL.md definitions
  ├── memory/              → Short-term + long-term memory
  └── hooks/               → Lifecycle callbacks
Foundation (config/, providers/, envs/, constant.py)
```

Dependency direction: `cli → app → agents → config`. Never reverse.

## Full Message Processing Trace

When tracing an end-to-end request:

```
Channel SDK callback (e.g. dingtalk-stream)
  → BaseChannel._enqueue(native_payload)
  → ChannelManager async queue (maxsize=1000, 4 workers/channel)
  → Worker dequeue → Channel.consume_one(payload)
    → build_agent_request_from_native(payload) → AgentRequest
    → Debounce/merge (same session_id within window)
    → runner.stream_query(request)
      → SafeJSONSession.load_session_state(session_id)
      → CoPawAgent.reply(msg)
        → process_file_and_media_blocks_in_message(msg)
        → CommandHandler.is_command(query)?
          Yes → handle_command() → return Msg
          No  → super().reply(msg)  # parent ReActAgent
            → pre_reasoning hooks:
              1. BootstrapHook  (inject BOOTSTRAP.md on first message)
              2. MemoryCompactionHook  (auto-compress if tokens > threshold)
            → ReAct Loop (max_iters=50):
              Think: LLM generates text + tool_use blocks
              Act:   Toolkit dispatches to registered functions
              Observe: ToolResponse(content=[TextBlock(...)]) returned
              Repeat until final answer or max_iters
      → SafeJSONSession.save_session_state(session_id)
    → Channel.send_event(event)
      → MessageRenderer.message_to_parts(msg)  # adapt to channel format
      → Channel.send(to_handle, text, meta)     # platform SDK send
```

## Analysis Dimensions

For any code section, analyze along these axes:

| Dimension | Focus |
|-----------|-------|
| **Data flow** | Where data originates, how it transforms, where it ends up |
| **Error handling** | Caught vs uncaught exceptions, silent failures, fallback paths |
| **Concurrency** | Async correctness, queue backpressure, lock granularity |
| **Config dependency** | Which config fields are read, behavior on missing config |
| **Extension points** | Does it follow BaseChannel/BaseTool interface patterns |
| **State lifecycle** | Where state lives (memory/file), when created/destroyed |

## Async Patterns

CoPaw mixes sync and async code:
- **Async**: channel communication, Runner execution, MCP connections, cron execution, hooks
- **Sync**: config loading, file I/O tools, CLI commands
- **Thread-safe enqueue**: `ChannelManager.enqueue()` is thread-safe (channel SDK callbacks may run in non-asyncio threads)

## Key Files Quick Reference

| To understand... | Read this file |
|-----------------|----------------|
| App lifecycle | `src/copaw/app/_app.py` (lifespan) |
| Agent init & reply | `src/copaw/agents/react_agent.py` |
| Tool registration | `react_agent.py` → `_create_toolkit()` |
| System prompt | `src/copaw/agents/prompt.py` |
| Channel base class | `src/copaw/app/channels/base.py` |
| Channel registry | `src/copaw/app/channels/registry.py` |
| Queue/worker model | `src/copaw/app/channels/manager.py` |
| Session persistence | `src/copaw/app/runner/session.py` |
| Memory compaction | `src/copaw/agents/hooks/memory_compaction.py` |
| Config model | `src/copaw/config/config.py` |
| Global constants | `src/copaw/constant.py` |

## Output Format

Structure analysis results as:

1. **Module location**: Layer and module the code belongs to
2. **Core responsibility**: What problem this code solves
3. **Data flow diagram**: ASCII diagram showing data flow
4. **Critical paths**: Performance/security-sensitive code paths
5. **Potential issues**: Bugs, bottlenecks, or design flaws
6. **Improvement suggestions**: Concrete proposals following project conventions
