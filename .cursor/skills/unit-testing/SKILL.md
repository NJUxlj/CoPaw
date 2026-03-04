---
name: unit-testing
description: "Write, run, and debug unit tests for the CoPaw project using pytest. Use when users ask to write tests, add test coverage, create test cases, mock dependencies, run pytest, debug failing tests, or improve test quality for this Python/FastAPI/async personal AI assistant codebase."
---

# Unit Testing for CoPaw

Write high-quality pytest tests following CoPaw's conventions and async patterns.

## Test Infrastructure

| Tool | Purpose | Config |
|------|---------|--------|
| pytest | Test framework | `pyproject.toml` `[tool.pytest.ini_options]` |
| pytest-asyncio | Async tests | `asyncio_mode = "auto"` |
| pytest-cov | Coverage | `--cov=copaw` |
| unittest.mock | Mock/Patch | Python stdlib |

### Commands

```bash
pytest                        # all tests
pytest -m "not slow"          # exclude slow
pytest -k "test_config"       # name match
pytest --cov=copaw            # with coverage
pytest -x                     # stop on first failure
```

### Test Markers

```python
@pytest.mark.slow       # browser/network/LLM tests
# @pytest.mark.asyncio  # not needed when asyncio_mode="auto"
```

## Test File Convention

Place tests in `tests/` directory mirroring `src/copaw/` structure:

```
tests/
├── test_config.py           # tests for config/
├── test_cron_models.py      # tests for app/crons/models.py
├── test_provider_models.py  # tests for providers/models.py
├── app/
│   ├── test_runner.py
│   └── test_channel_manager.py
└── agents/
    └── test_command_handler.py
```

## Module Testing Strategies

### Pydantic Models (Priority 1 — no mocks needed)

Test validation, defaults, and backward compatibility. These are the highest-value, lowest-effort tests.

```python
# -*- coding: utf-8 -*-
from copaw.config.config import Config, HeartbeatConfig
from copaw.app.crons.models import ScheduleSpec, CronJobSpec


class TestConfig:
    def test_default_config_is_valid(self):
        config = Config()
        assert config.channels.console.enabled is True
        assert config.show_tool_details is True

    def test_heartbeat_defaults(self):
        hb = HeartbeatConfig()
        assert hb.every == "30m"
        assert hb.target == "main"


class TestScheduleSpec:
    def test_valid_5_field_cron(self):
        s = ScheduleSpec(cron="0 9 * * 1")
        assert s.cron == "0 9 * * 1"

    def test_4_field_auto_normalize(self):
        s = ScheduleSpec(cron="9 * * 1")
        assert s.cron == "0 9 * * 1"

    def test_6_field_rejected(self):
        with pytest.raises(ValueError):
            ScheduleSpec(cron="0 0 0 0 0 0")
```

### JSON Repositories (Priority 2 — use tmp_path)

```python
import json
from copaw.app.crons.repo.json_repo import JsonJobRepository
from copaw.app.crons.models import JobsFile


class TestJsonJobRepository:
    def test_load_empty(self, tmp_path):
        path = tmp_path / "jobs.json"
        path.write_text("{}")
        repo = JsonJobRepository(path)
        result = repo.load()
        assert isinstance(result, JobsFile)
        assert result.jobs == []
```

### Provider System (Priority 2)

```python
from copaw.providers.models import (
    ProvidersData,
    ProviderDefinition,
    ProviderSettings,
    CustomProviderData,
)


class TestProvidersData:
    def test_get_credentials_builtin(self):
        data = ProvidersData(
            providers={
                "dashscope": ProviderSettings(
                    api_key="sk-xxx",
                    base_url="https://api.example.com",
                ),
            },
        )
        url, key = data.get_credentials("dashscope")
        assert key == "sk-xxx"

    def test_local_provider_always_configured(self):
        defn = ProviderDefinition(
            id="local", name="Local", is_local=True,
        )
        assert ProvidersData().is_configured(defn) is True
```

### Agent Commands (Priority 3 — light mocking)

```python
from unittest.mock import MagicMock
from copaw.agents.command_handler import CommandHandler


class TestCommandHandler:
    def test_recognizes_commands(self):
        handler = CommandHandler(agent=MagicMock())
        assert handler.is_command("/compact") is True
        assert handler.is_command("/new") is True
        assert handler.is_command("hello") is False
```

### Channels & Runner (Priority 3 — heavy mocking)

```python
from unittest.mock import AsyncMock, MagicMock


class TestChannelManager:
    async def test_send_text_routes_correctly(self):
        channel = MagicMock()
        channel.channel = "console"
        channel.send = AsyncMock()
        # ... create manager, call send_text, assert channel.send called
```

## Mock Strategy

| Module under test | Mock these dependencies |
|-------------------|----------------------|
| CronExecutor | AgentRunner, ChannelManager |
| ChannelManager | BaseChannel instances, asyncio.Queue |
| AgentRunner | CoPawAgent, SafeJSONSession |
| CoPawAgent | LLM Client, Toolkit, MemoryManager |
| ConfigWatcher | File system events, ChannelManager |
| MCPClientManager | StdIOStatefulClient |
| Skills loading | File system (use `tmp_path`) |

## Key Principles

1. **Prioritize Pydantic models and pure functions** — no mocks needed, high coverage
2. **Async tests use `async def test_*`** — `asyncio_mode = "auto"` handles the rest
3. **Use `tmp_path` fixture for file operations** — never touch real filesystem
4. **Mark slow tests `@pytest.mark.slow`** — anything with network, browser, or LLM
5. **Mock external interfaces, not internal data structures**
6. **One assertion focus per test** — clear Arrange-Act-Assert structure
7. **Test validation boundaries** — especially Pydantic validators and field constraints
