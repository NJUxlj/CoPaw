---
name: code-review
description: "Review CoPaw code changes for correctness, security, performance, and maintainability. Use when users ask to review code, evaluate a PR, check code quality, audit security, verify architectural consistency, or validate changes against project conventions."
---

# Code Review for CoPaw

Perform thorough code reviews against CoPaw's standards. Check each dimension below in order.

## 1. Coding Standards (Must Check)

**Python:**
- Line width ≤ 79 characters (Black)
- Double-quoted strings
- File header `# -*- coding: utf-8 -*-`
- Trailing commas (enforced by pre-commit)
- Type annotations on function signatures
- Logging via `logger = logging.getLogger(__name__)`
- No bare `except:` (at minimum `except Exception:`)
- Import order: stdlib → third-party → project

**TypeScript (Console):**
- Prettier formatted
- ESLint passing
- User-visible text uses `t("key")` for i18n
- Both `en.json` and `zh.json` updated

## 2. Architecture Consistency (Must Check)

- **Dependency direction**: `cli → app → agents → config` — never reversed
- **Layer separation**: No business logic in router layer, no routing in agent layer
- **Interface compliance**: New channels inherit `BaseChannel`, new repos inherit `Base*Repository`
- **Config pattern**: New config fields defined as Pydantic models in `config/config.py` with defaults
- **Lazy loading**: `agents/__init__.py` `__getattr__` pattern not broken
- **Atomic writes**: JSON file writes use `.tmp` + `replace` pattern
- **Lifespan cleanup**: New components cleaned up in `_app.py` lifespan `finally` block

## 3. Personal Assistant Security (Critical)

CoPaw runs locally with full system permissions — security review is paramount:

- **Shell injection**: Is `execute_shell_command` input LLM-controllable? Any sandbox boundary?
- **Path traversal**: Can `read_file`/`write_file` access files outside working directory?
- **API key leaks**: Can sensitive info appear in logs, error messages, or agent responses?
- **Channel auth**: Does the new channel verify message origin? Is there an allowlist?
- **Skill injection**: Can a third-party SKILL.md inject malicious instructions?
- **MCP trust**: Are MCP tool call results treated as trusted input?
- **Env protection**: Does `envs.json` sensitive data have proper access control?

## 4. Concurrency & Async (Important)

- **Blocking in async**: Any blocking I/O in async functions? (Should use `asyncio.to_thread`)
- **Queue backpressure**: ChannelManager queues have maxsize=1000 — do new queues also have limits?
- **Lock granularity**: Session-level locks — appropriate granularity? Deadlock risk?
- **Graceful shutdown**: New components cleaned up in lifespan `finally` block?
- **State consistency**: `save_session_state` called on all paths including exception paths?

## 5. Error Handling (Important)

- **No silent swallowing**: `except Exception: pass` must have clear justification (e.g., shutdown phase)
- **Error dumps**: Agent execution failures trigger `write_query_error_dump`?
- **User-friendly**: Errors returned in user-understandable form (no internal stack traces)?
- **Retry logic**: Network operations (channel sends, MCP connections) have retry?
- **Graceful degradation**: Optional features (MCP, memory manager) fail gracefully without crashing?

## 6. Performance (As Needed)

- **Token cost**: Do new system prompts or skill instructions significantly increase token usage?
- **File I/O frequency**: Is JSON read/write frequency reasonable? Need caching?
- **Memory leaks**: Any uncleaned sessions or accumulating push messages in long-running processes?
- **Startup time**: Do new dependencies impact `copaw app` startup? (Respect lazy loading)

## 7. Test Coverage (Expected)

- Core logic has corresponding pytest tests?
- Async code uses `pytest-asyncio`?
- Pydantic models have boundary validation tests?
- Slow tests marked with `@pytest.mark.slow`?

## Output Format

```
## Review Summary

**Change overview**: One-line description of the change purpose
**Risk level**: 🟢 Low / 🟡 Medium / 🔴 High
**Recommendation**: ✅ Approve / ⚠️ Request changes / ❌ Needs redesign

## Issues

### [SEVERITY] file:line — Issue title
Description of the problem.
Suggested fix (with code example).
```

Severity levels:
- 🔴 **BLOCKER**: Must fix (security vulnerability, data loss, crash)
- 🟠 **MAJOR**: Strongly recommend (architecture violation, concurrency issue)
- 🟡 **MINOR**: Recommend (coding standards, readability)
- 🔵 **NIT**: Optional (style preference, comment suggestion)
