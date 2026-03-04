---
name: copaw-dev
description: Start the CoPaw local-first personal AI assistant and run various tests. Use when users want to start the CoPaw server, run unit tests, check code quality, or perform development tasks on this Python/FastAPI/async codebase.
---

# CoPaw Development

Guide for starting the CoPaw server and running tests.

## Quick Start

### Start the Server

```bash
# Initialize (if first time)
copaw init --defaults

# Start the server on port 8088
copaw app
```

### Run Tests

```bash
# All tests
pytest

# Skip slow tests (browser/network/LLM)
pytest -m "not slow"

# With coverage
pytest --cov=copaw

# Specific test by name
pytest -k test_config
```

## Installation

### 方式一：使用 Conda 创建环境（推荐）

```bash
# 创建 Python 3.12 环境
conda create -n copaw python=3.12 -y
conda activate copaw

# 从源码安装（editable 模式）
pip install -e ".[dev]"

# 可选：llama.cpp 支持
pip install -e ".[llamacpp]"

# 可选：MLX 支持（Apple Silicon）
pip install -e ".[mlx]"
```

### 方式二：直接使用 pip

```bash
# Editable install with dev dependencies
pip install -e ".[dev]"

# Optional: llama.cpp support
pip install -e ".[llamacpp]"

# Optional: MLX support (Apple Silicon)
pip install -e ".[mlx]"
```

## Development Commands

### Code Quality

```bash
# Install pre-commit hooks
pre-commit install

# Run all checks
pre-commit run --all-files
```

### Console Frontend (React + Vite)

```bash
cd console
npm ci && npm run dev    # Dev server with HMR
npm run build            # Production build
npm run format           # Prettier
npm run lint             # ESLint
```

## Working Directory Structure

```
~/.copaw/
├── config.json           # Main config
├── providers.json        # LLM providers
├── envs.json             # Environment variables
├── jobs.json             # Cron jobs
├── chats.json            # Chat sessions
├── HEARTBEAT.md          # Heartbeat tasks
├── md_files/             # Agent persona files
├── memory/               # Long-term memory
├── active_skills/        # Active skills
├── customized_skills/    # User skills
├── custom_channels/      # Custom channels
├── models/               # Downloaded models
└── sessions/             # Session states
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COPAW_WORKING_DIR` | `~/.copaw` | Data storage |
| `COPAW_PORT` | `8088` | Server port |
| `COPAW_LOG_LEVEL` | `info` | Logging level |
| `COPAW_ENABLED_CHANNELS` | all | Comma-separated filter |

## Testing Guidelines

- Use `pytest -m "not slow"` for quick feedback
- Slow tests involve browser, network, or LLM calls
- Tests are in `tests/` directory
- Use `pytest --cov=copaw` for coverage reports

## Quick Test

```bash
# 测试配置系统
python -c "from copaw.config.config import Config; c = Config(); print('✅ Config OK')"

# 测试工具导入
python -c "from copaw.agents.tools.shell import execute_shell_command; print('✅ Tools OK')"

# 测试 CLI
copaw --help
```

## Project Structure

```
src/copaw/
├── agents/           # Core intelligence (ReAct agent, tools, skills)
├── app/              # FastAPI app (channels, runners, crons, MCP)
├── cli/              # CLI commands
├── config/           # Configuration management
├── providers/        # LLM provider registry
├── envs/             # Environment manager
└── local_models/     # Local model backends
```
