# CoPaw 命令行实现方式详解

## 1. 概述

CoPaw CLI 是基于 **Click** 框架构建的 Python 命令行应用，采用 **分组命令（Group Command）** 架构。所有命令都注册到一个顶层 `cli` 对象上，通过子命令组的方式组织和管理。

### 核心技术栈
- **Click**: 命令行框架，提供装饰器风格的命令定义
- **httpx**: HTTP 客户端，用于与 FastAPI 后端通信
- **questionary**: 交互式提示（向导式配置）
- **rich**: 富文本输出美化

---

## 2. 核心入口：main.py

### 2.1 顶层 cli 对象

```python
@click.group(context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(version=__version__, prog_name="CoPaw")
@click.option("--host", default=None, help="API Host")
@click.option("--port", default=None, type=int, help="API Port")
@click.pass_context
def cli(ctx: click.Context, host: str | None, port: int | None) -> None:
```

这是整个 CLI 的入口点，核心职责：

1. **全局参数管理**：通过 `ctx.obj` 字典在所有子命令间共享 `host` 和 `port`
2. **配置回退机制**：
   - 优先使用命令行传入的 `--host/--port`
   - 其次读取 `read_last_api()` 返回的上次运行配置
   - 最终默认到 `127.0.0.1:8088`

### 2.2 命令注册方式

```python
cli.add_command(app_cmd)
cli.add_command(channels_group)
cli.add_command(daemon_group)
# ... 其他命令
```

所有子命令通过 `cli.add_command()` 显式注册到顶层 Group。

### 2.3 导入结构（计时加载）

```python
_t = time.perf_counter()
from .app_cmd import app_cmd  # noqa: E402
_record(".app_cmd", time.perf_counter() - _t)
```

采用**计时导入**模式，记录每个模块的加载时间，便于性能分析和调试。

---

## 3. 各指令实现详解

### 3.1 `copaw app` - 应用启动

**文件**: `app_cmd.py`

```python
@click.command("app")
@click.option("--host", default="127.0.0.1", ...)
@click.option("--port", default=8088, type=int, ...)
@click.option("--reload", is_flag=True, ...)
@click.option("--workers", default=1, type=int, ...)
@click.option("--log-level", default="info", ...)
```

**核心功能**：
- 使用 **Uvicorn** 启动 FastAPI 应用
- 持久化 `host/port` 到 `last_api.txt`，供其他 CLI 命令连接
- 设置 `LOG_LEVEL_ENV` 环境变量，控制日志级别
- 支持 `reload` 模式用于开发

**关键实现**：
```python
uvicorn.run(
    "copaw.app._app:app",  # 导入字符串，延迟加载
    host=host,
    port=port,
    reload=reload,
    workers=workers,
    log_level=log_level,
)
```

---

### 3.2 `copaw channels` - 渠道配置

**文件**: `channels_cmd.py`

这是一个**交互式配置命令**，核心流程：

#### 3.2.1 配置流程

```
channels list  → 显示所有已配置的渠道
channels config → 交互式配置向导
channels install <key> → 安装自定义渠道模板
```

#### 3.2.2 支持的渠道类型

| 渠道 | 配置类 | 特殊参数 |
|------|--------|----------|
| iMessage | `IMessageChannelConfig` | `db_path`, `poll_sec` |
| Discord | `DiscordConfig` | `bot_token`, `http_proxy` |
| Telegram | `TelegramConfig` | `bot_token` |
| DingTalk | `DingTalkConfig` | `client_id`, `client_secret` |
| Feishu | `FeishuConfig` | `app_id`, `app_secret` |
| QQ | `QQConfig` | `account`, `password` |
| Console | `ConsoleConfig` | - |
| Voice (Twilio) | `VoiceChannelConfig` | `twilio_auth_token` |

#### 3.2.3 交互式配置函数

每个渠道都有对应的 `configure_xxx()` 函数，例如 `configure_imessage()`:

```python
def configure_imessage(current_config: IMessageChannelConfig):
    enabled = prompt_confirm("Enable iMessage channel?", default=...)
    # ... 收集各种配置参数
    return current_config
```

#### 3.2.4 自定义渠道安装

`copaw channels install <key>` 会生成渠道模板代码：
```python
CHANNEL_TEMPLATE = '''# -*- coding: utf-8 -*-
"""Custom channel: {key}. Edit and implement required methods."""
from copaw.app.channels.base import BaseChannel

class CustomChannel(BaseChannel):
    channel: ChannelType = "{key}"
    # ... 必须实现的方法
'''
```

---

### 3.3 `copaw chats` - 聊天会话管理

**文件**: `chats_cmd.py`

通过 **HTTP API** 与后端通信，实现 CRUD 操作：

| 子命令 | HTTP 方法 | 端点 | 功能 |
|--------|-----------|------|------|
| `chats list` | GET | `/chats` | 列出所有会话 |
| `chats get <chat_id>` | GET | `/chats/{id}` | 获取会话详情 |
| `chats create` | POST | `/chats` | 创建会话 |
| `chats update` | PUT | `/chats/{id}` | 更新会话 |
| `chats delete` | DELETE | `/chats/{id}` | 删除会话 |

#### URL 解析优先级

```python
def _base_url(ctx: click.Context, base_url: Optional[str]) -> str:
    # 1. 命令行 --base-url
    # 2. 全局 --host/--port (存储在 ctx.obj)
    # 3. 默认 http://127.0.0.1:8088
```

---

### 3.4 `copaw cron` - 定时任务管理

**文件**: `cron_cmd.py`

#### 子命令

| 子命令 | 功能 |
|--------|------|
| `cron list` | 列出所有定时任务 |
| `cron get <job_id>` | 获取任务详情 |
| `cron state <job_id>` | 查看运行时状态 |
| `cron create` | 创建定时任务 |
| `cron delete <job_id>` | 删除任务 |
| `cron pause <job_id>` | 暂停任务 |
| `cron resume <job_id>` | 恢复任务 |
| `cron run <job_id>` | 手动触发一次 |

#### 任务类型

- **`text`**: 发送固定文本到渠道
- **`agent`**: 发送问题给 AI agent，将回复投递到渠道

#### 创建任务示例

```python
# 构建 CronJobSpec
_spec = {
    "id": "",
    "name": name,
    "schedule": {"type": "cron", "cron": cron_expr, "timezone": tz},
    "task_type": "text|agent",
    "text": "内容",
    "dispatch": {"type": "channel", "channel": channel, "target": {...}},
    "runtime": {"max_concurrency": 1, "timeout_seconds": 120},
}
```

---

### 3.5 `copaw daemon` - 守护进程管理

**文件**: `daemon_cmd.py`

直接调用 `daemon_commands.py` 中的业务逻辑：

```python
from ..app.runner.daemon_commands import (
    run_daemon_status,
    run_daemon_restart,
    run_daemon_reload_config,
    run_daemon_version,
    run_daemon_logs,
)
```

| 子命令 | 功能 |
|--------|------|
| `daemon status` | 查看守护进程状态 |
| `daemon restart` | 重启守护进程 |
| `daemon reload-config` | 热重载配置 |
| `daemon version` | 查看版本信息 |
| `daemon logs` | 查看日志 |

---

### 3.6 `copaw models` (providers) - LLM 提供商管理

**文件**: `providers_cmd.py`

#### 功能

- 交互式配置 API Key 和 Base URL
- 管理每个提供商的模型列表
- 选择默认的 LLM 模型

#### 关键函数

```python
configure_provider_api_key_interactive(provider_id)
_add_models_interactive(provider_id)
_select_llm_model(defn, pid, current_slot, use_defaults=False)
configure_llm_slot_interactive()
```

---

### 3.7 `copaw skills` - 技能管理

**文件**: `skills_cmd.py`

| 子命令 | 功能 |
|--------|------|
| `skills list` | 列出所有技能及状态 |
| `skills config` | 交互式启用/禁用技能 |

#### 核心实现

```python
from ..agents.skills_manager import SkillService, list_available_skills

# 多选框交互
selected = prompt_checkbox(
    "Select skills to enable:",
    options=options,
    checked=default_checked,
)
```

---

### 3.8 `copaw env` - 环境变量管理

**文件**: `env_cmd.py`

```python
@env_group.command("list")
@env_group.command("set")
@env_group.command("delete")
```

底层调用 `envs.py` 中的函数：
```python
from ..envs import load_envs, set_env_var, delete_env_var
```

---

### 3.9 `copaw init` - 初始化向导

**文件**: `init_cmd.py`

完整的交互式初始化流程：

```
1. 显示安全警告（Rich Panel）
2. 显示遥测信息
3. 配置环境变量 (env_cmd)
4. 配置 LLM 提供商 (providers_cmd)
5. 配置渠道 (channels_cmd)
6. 配置技能 (skills_cmd)
7. 生成 heartbeat.md
```

---

### 3.10 `copaw desktop` - 桌面模式

**文件**: `desktop_cmd.py`

使用 **webview** 库在原生窗口中运行：

```python
# 1. 查找空闲端口
port = _find_free_port(host)

# 2. 启动 FastAPI 子进程
subprocess.Popen(["copaw", "app", "--port", str(port)])

# 3. 等待服务就绪
_wait_for_http(host, port)

# 4. 在 webview 中打开
import webview
webview.create_window("CoPaw", url)
```

---

### 3.11 `copaw clean` - 清理工作目录

**文件**: `clean_cmd.py`

```python
# 保留 telemetry marker 文件
telemetry_marker = wd / TELEMETRY_MARKER_FILE
children = [c for c in children if c != telemetry_marker]
```

支持 `--dry-run` 和 `--yes` 参数。

---

### 3.12 `copaw update` - 更新 CoPaw

**文件**: `update_cmd.py`

- 检测 PyPI 最新版本
- 升级 pip 包
- 管理 CoPaw 服务重启

---

### 3.13 `copaw shutdown` - 关闭服务

**文件**: `shutdown_cmd.py`

通过 HTTP API 或进程信号关闭运行中的 CoPaw 服务。

---

### 3.14 `copaw uninstall` - 卸载

**文件**: `uninstall_cmd.py`

1. 移除 `venv/bin` 目录
2. 清理 shell profile 中的 PATH 条目
3. 可选：`--purge` 删除所有数据

---

## 4. 公共工具模块

### 4.1 `http.py` - HTTP 客户端封装

```python
def client(base_url: str) -> httpx.Client:
    base = base_url.rstrip("/")
    if not base.endswith("/api"):
        base = f"{base}/api"
    return httpx.Client(base_url=base, timeout=30.0)
```

所有 HTTP 请求自动添加 `/api` 前缀。

### 4.2 `utils.py` - 交互式提示工具

| 函数 | 功能 |
|------|------|
| `prompt_confirm()` | Yes/No 确认 |
| `prompt_path()` | 路径输入（带存在性检查） |
| `prompt_choice()` | 单选列表 |
| `prompt_select()` | 带标签的单选 |
| `prompt_checkbox()` | 多选框（支持全选） |

### 4.3 `process_utils.py` - 进程工具

- `_is_copaw_service_command()`: 检测命令是否为 CoPaw 服务
- `_windows_process_snapshot()`: Windows 进程快照
- `_process_table()`: 进程列表格式化

---

## 5. 架构图

```
                              ┌─────────────────────────────────┐
                              │          用户输入               │
                              │    copaw <command> [options]    │
                              └───────────────┬─────────────────┘
                                              │
                                              ▼
                              ┌─────────────────────────────────┐
                              │        main.py: cli()            │
                              │  ┌─────────────────────────────┐ │
                              │  │ • @click.group 顶层组        │ │
                              │  │ • --host/--port 全局选项    │ │
                              │  │ • ctx.obj 共享状态          │ │
                              │  └─────────────────────────────┘ │
                              │            │                       │
                              │    cli.add_command(...)          │
                              └────────────┼─────────────────────┘
                                           │
          ┌──────────────┬──────────────┬───┴────┬──────────────┬──────────────┐
          │              │              │        │              │              │
          ▼              ▼              ▼        ▼              ▼              ▼
    ┌───────────┐  ┌───────────┐  ┌───────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ app_cmd   │  │channels_  │  │ chats_    │ │  cron_   │ │ daemon_  │ │  models_ │
    │           │  │ cmd       │  │ cmd       │ │  cmd     │ │ cmd      │ │  cmd     │
    │ 启动      │  │ 渠道      │  │ 聊天会话  │ │  定时    │ │ 守护进程 │ │ LLM      │
    │ FastAPI   │  │ 配置向导  │  │ HTTP API  │ │  任务    │ │ 管理     │ │ 提供商   │
    └─────┬─────┘  └─────┬─────┘  └─────┬─────┘ └────┬─────┘ └─────┬─────┘ └────┬────┘
          │              │              │        │              │              │
          ▼              ▼              ▼        ▼              ▼              ▼
    ┌───────────┐  ┌───────────┐  ┌───────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ uvicorn   │  │ config/   │  │  http.py  │ │  http.py │ │ daemon_  │ │providers_│
    │.run()     │  │ config.py │  │ httpx     │ │  httpx   │ │commands  │ │ manager  │
    │           │  │           │  │ Client    │ │  Client  │ │ .py      │ │          │
    └─────┬─────┘  └─────┬─────┘  └─────┬─────┘ └────┬─────┘ └─────┬─────┘ └────┬────┘
          │              │              │        │              │              │
          ▼              ▼              ▼        ▼              ▼              ▼
    ┌───────────┐  ┌───────────┐  ┌─────────────────────────────────────────────────┐
    │ FastAPI   │  │  File:    │  │                  HTTP API                       │
    │ Backend   │  │ config.   │  │              (chats, cron, etc.)                │
    │           │  │ json      │  │                                                │
    └───────────┘  └───────────┘  └─────────────────────────────────────────────────┘


    ┌─────────────────────────────────────────────────────────────────────────────┐
    │                         CLI 内部模块依赖关系                                  │
    ├─────────────────────────────────────────────────────────────────────────────┤
    │                                                                             │
    │   ┌──────────────┐     ┌──────────────┐                                    │
    │   │   main.py    │────▶│  process_    │                                    │
    │   │  (入口/分发)  │     │  utils.py    │                                    │
    │   └──────┬───────┘     └──────────────┘                                    │
    │          │                                                                │
    │          │  ┌──────────────┐     ┌──────────────┐                          │
    │          ├──▶│   http.py    │────▶│   httpx      │                          │
    │          │  │ (HTTP客户端) │     │  Library     │                          │
    │          │  └──────────────┘     └──────────────┘                          │
    │          │                                                                │
    │          │  ┌──────────────┐     ┌──────────────┐                          │
    │          └──▶│   utils.py   │────▶│ questionary  │                          │
    │          │  │(交互式提示)   │     │  Library     │                          │
    │          │  └──────────────┘     └──────────────┘                          │
    │          │                                                                │
    │          │  ┌──────────────────────────────────────────┐                   │
    │          └──▶│              业务命令模块                │                   │
    │             │  ┌────────┐ ┌────────┐ ┌────────┐      │                   │
    │             │  │app_cmd │ │channels│ │ chats  │ ...  │                   │
    │             │  │        │ │_cmd    │ │_cmd    │      │                   │
    │             │  └────┬────┘ └───┬────┘ └───┬────┘      │                   │
    │             └───────┼──────────┼──────────┼──────────┘                   │
    │                      │          │          │                              │
    │                      ▼          ▼          ▼                              │
    │             ┌──────────────────────────────────────────┐                   │
    │             │              业务层模块                  │                   │
    │             │  ┌────────┐ ┌────────┐ ┌────────┐       │                   │
    │             │  │ config │ │providers│ │ agents │ ...  │                   │
    │             │  │        │ │        │ │        │       │                   │
    │             │  └────────┘ └────────┘ └────────┘       │                   │
    │             └──────────────────────────────────────────┘                   │
    │                                                                     │
    └─────────────────────────────────────────────────────────────────────────────┘


    ┌─────────────────────────────────────────────────────────────────────────────┐
    │                         命令调用流程（以 chats 为例）                        │
    ├─────────────────────────────────────────────────────────────────────────────┤
    │                                                                             │
    │  $ copaw chats list --user-id alice                                       │
    │         │                                                                  │
    │         ▼                                                                  │
    │  ┌─────────────────────────────────────────────┐                           │
    │  │ main.py: cli()                               │                           │
    │  │ 1. 解析 --host/--port                        │                           │
    │  │ 2. ctx.obj["host"] = "127.0.0.1"            │                           │
    │  │ 3. ctx.obj["port"] = 8088                   │                           │
    │  └─────────────────────┬───────────────────────┘                           │
    │                        │                                                    │
    │                        ▼                                                    │
    │  ┌─────────────────────────────────────────────┐                           │
    │  │ chats_cmd.py: list_chats()                  │                           │
    │  │ 1. _base_url() → http://127.0.0.1:8088     │                           │
    │  │ 2. client(base_url) → httpx.Client         │                           │
    │  │ 3. c.get("/chats", params={...})           │                           │
    │  │ 4. print_json(response)                     │                           │
    │  └─────────────────────────────────────────────┘                           │
    │                                                                     │
    └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 关键设计模式

### 6.1 Click Group 嵌套

子命令可以是 `Group`（如 `chats_group`）或普通 `Command`（如 `app_cmd`），Group 可以包含多个 Command。

### 6.2 Context 传递

使用 `@click.pass_context` 在命令间共享状态：
```python
ctx.obj["host"]  # 全局 host
ctx.obj["port"]  # 全局 port
```

### 6.3 HTTP API 封装

所有需要与后端通信的命令都通过 `http.py` 的 `client()` 函数创建连接，自动处理 URL 前缀和超时。

### 6.4 交互式配置模式

使用 `questionary` 库提供交互式配置界面，通过 `utils.py` 封装统一入口。

### 6.5 延迟导入

在 `main.py` 中使用计时导入，便于识别性能瓶颈：
```python
_t = time.perf_counter()
from .app_cmd import app_cmd
_record(".app_cmd", time.perf_counter() - _t)
```
