# `_app.py` 文件详解

> 文件路径: `src/copaw/app/_app.py`
>
> 角色: CoPaw 的**应用入口**——创建 FastAPI 实例、编排所有组件的生命周期、挂载 API 路由、托管前端静态文件。

---

## 目录

1. [文件在架构中的位置](#1-文件在架构中的位置)
2. [模块级初始化（第 1–45 行）](#2-模块级初始化第-145-行)
3. [生命周期管理 `lifespan()`（第 48–138 行）](#3-生命周期管理-lifespan第-48138-行)
4. [FastAPI 实例创建（第 141–146 行）](#4-fastapi-实例创建第-141146-行)
5. [前端静态文件服务（第 149–232 行）](#5-前端静态文件服务第-149232-行)
6. [API 路由挂载（第 189–195 行）](#6-api-路由挂载第-189195-行)
7. [组件交互关系图](#7-组件交互关系图)
8. [关键设计模式](#8-关键设计模式)
9. [启动/关闭时序](#9-启动关闭时序)
10. [常见修改场景](#10-常见修改场景)

---

## 1. 文件在架构中的位置

```
CoPaw 四层架构:

┌─────────────────────────────────────────────────────┐
│  CLI Layer (copaw app / copaw init / ...)           │
├─────────────────────────────────────────────────────┤
│  App Layer ← _app.py 就在这一层                      │
│  ┌─────────┬──────────┬──────────┬────────────────┐ │
│  │ Runner  │ Channels │  Crons   │  MCP Manager   │ │
│  │         │ Manager  │ Manager  │  + Watcher     │ │
│  └────┬────┴────┬─────┴────┬─────┴───────┬────────┘ │
├───────┼─────────┼──────────┼─────────────┼──────────┤
│  Agent Layer    │          │             │           │
│  CoPawAgent ────┘          │             │           │
│  (ReActAgent + Skills      │             │           │
│   + Memory + Tools)        │             │           │
├────────────────────────────┼─────────────┼──────────┤
│  Foundation Layer          │             │           │
│  Config / Providers / Constant / Envs    │           │
└──────────────────────────────────────────┴──────────┘
```

`_app.py` 是 App Layer 的核心编排文件。它不包含任何业务逻辑，只负责：
- **创建组件**（Runner, ChannelManager, CronManager, MCPClientManager 等）
- **定义启动/关闭顺序**
- **将组件注入 `app.state`** 供路由使用
- **挂载 API 路由和静态文件**

---

## 2. 模块级初始化（第 1–45 行）

```python
# 第 33 行：设置日志
logger = setup_logger(os.environ.get(LOG_LEVEL_ENV, "info"))

# 第 37 行：加载持久化环境变量
load_envs_into_environ()

# 第 39 行：创建全局 AgentRunner 实例
runner = AgentRunner()

# 第 41-45 行：创建 AgentApp（agentscope-runtime 的标准应用壳）
agent_app = AgentApp(
    app_name="Friday",
    app_description="A helpful assistant",
    runner=runner,
)
```

### 逐行解析

#### `setup_logger()` — 日志初始化

```python
logger = setup_logger(os.environ.get(LOG_LEVEL_ENV, "info"))
```

- 从 `COPAW_LOG_LEVEL` 环境变量读取日志级别，默认 `"info"`
- 在模块导入时就执行，确保 `uvicorn --reload` 的子进程也使用相同的日志级别
- `setup_logger()` 来自 `copaw.utils.logging`，配置了 `ColorFormatter` 和 `SuppressPathAccessLogFilter`（抑制静态资源访问日志）

#### `load_envs_into_environ()` — 环境变量预加载

```python
load_envs_into_environ()
```

- 从 `~/.copaw/envs.json` 读取用户通过 Console UI 设置的环境变量（如 `DASHSCOPE_API_KEY`）
- 调用 `os.environ[key] = value` 注入到当前进程
- **必须在 `lifespan()` 之前执行**，因为后续的 `load_config()`、Channel SDK 初始化等都可能读取这些环境变量

#### `AgentRunner()` — 全局 Runner 实例

```python
runner = AgentRunner()
```

`AgentRunner` 继承自 `agentscope_runtime.engine.runner.Runner`，是请求处理的核心：

| 方法 | 职责 |
|------|------|
| `init_handler()` | 加载 `.env`、创建 `SafeJSONSession`、启动 `MemoryManager` |
| `query_handler()` | 接收 `AgentRequest` → 创建 `CoPawAgent` → 流式执行 → 保存 session |
| `shutdown_handler()` | 关闭 `MemoryManager` |
| `set_chat_manager()` | 注入 `ChatManager`（自动注册/更新聊天记录） |
| `set_mcp_manager()` | 注入 `MCPClientManager`（热重载 MCP 工具） |

`runner` 是模块级单例，被 `lifespan()`、`ChannelManager`、`CronManager` 共同引用。

#### `AgentApp()` — AgentScope 标准应用

```python
agent_app = AgentApp(
    app_name="Friday",
    app_description="A helpful assistant",
    runner=runner,
)
```

- `AgentApp` 来自 `agentscope-runtime`，封装了标准的 agent 交互 API（`/process`、`/sessions` 等）
- `app_name="Friday"` 是 CoPaw agent 的内部名称
- 它的 `router` 后续会被挂载到 `/api/agent` 前缀下

---

## 3. 生命周期管理 `lifespan()`（第 48–138 行）

这是整个文件最核心的部分。`lifespan()` 是 FastAPI 的 [Lifespan 协议](https://fastapi.tiangolo.com/advanced/events/)，定义了应用的启动和关闭逻辑。

### 3.1 完整流程概览

```
┌─── 启动阶段（yield 之前） ───────────────────────────────┐
│                                                          │
│  1. runner.start()                                       │
│     └─ 调用 init_handler(): .env、Session、MemoryManager  │
│                                                          │
│  2. MCPClientManager.init_from_config()                  │
│     └─ 遍历 config.mcp.clients，创建 StdIOStatefulClient  │
│     └─ runner.set_mcp_manager(mcp_manager)               │
│                                                          │
│  3. ChannelManager.from_config()                         │
│     └─ 读取 config.channels，创建各 Channel 实例            │
│     └─ channel_manager.start_all()                       │
│        └─ 每个 channel 创建 Queue(1000) + 4 个 worker      │
│        └─ 调用每个 channel 的 start()                      │
│                                                          │
│  4. CronManager(repo, runner, channel_manager)           │
│     └─ cron_manager.start()                              │
│        └─ APScheduler 加载 jobs.json 中的任务               │
│                                                          │
│  5. ChatManager(repo=JsonChatRepository)                 │
│     └─ runner.set_chat_manager(chat_manager)             │
│                                                          │
│  6. ConfigWatcher(channel_manager)                       │
│     └─ config_watcher.start()                            │
│        └─ 启动 2s 轮询 config.json，检测 channel 变更       │
│                                                          │
│  7. MCPConfigWatcher(mcp_manager, ...)                   │
│     └─ mcp_watcher.start()                              │
│        └─ 启动 2s 轮询 config.json，检测 MCP 变更           │
│                                                          │
│  8. 注入 app.state.*（7 个组件）                            │
│                                                          │
├─── yield（应用运行中） ──────────────────────────────────────┤
│                                                          │
├─── 关闭阶段（finally 块） ─────────────────────────────────┤
│                                                          │
│  1. config_watcher.stop()      (停止 channel 配置监控)     │
│  2. mcp_watcher.stop()         (停止 MCP 配置监控)         │
│  3. cron_manager.stop()        (停止所有定时任务)            │
│  4. channel_manager.stop_all() (停止所有 channel)          │
│  5. mcp_manager.close_all()    (关闭所有 MCP 连接)          │
│  6. runner.stop()              (MemoryManager + Session)  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 3.2 逐段解析

#### 阶段 1: Runner 启动

```python
await runner.start()
```

`Runner.start()` 是 agentscope-runtime 的基类方法，内部调用 `init_handler()`：

```python
# runner.py → init_handler()
async def init_handler(self, *args, **kwargs):
    # 1. 加载 .env 文件（项目根目录向上4级）
    env_path = Path(__file__).resolve().parents[4] / ".env"
    if env_path.exists():
        load_dotenv(env_path)

    # 2. 创建 SafeJSONSession（会话持久化）
    session_dir = str(WORKING_DIR / "sessions")
    self.session = SafeJSONSession(save_dir=session_dir)

    # 3. 启动 MemoryManager（ReMe-AI 长期记忆）
    if self.memory_manager is None:
        self.memory_manager = MemoryManager(working_dir=str(WORKING_DIR))
    await self.memory_manager.start()
```

`SafeJSONSession` 将 agent 对话状态序列化到 `~/.copaw/sessions/` 目录。它的 `sanitize_filename()` 方法替换 `\ / : * ? " < > |` 为 `--`，确保跨平台文件名安全。

#### 阶段 2: MCP 客户端初始化

```python
config = load_config()
mcp_manager = MCPClientManager()
if hasattr(config, "mcp"):
    try:
        await mcp_manager.init_from_config(config.mcp)
        runner.set_mcp_manager(mcp_manager)
    except Exception:
        logger.exception("Failed to initialize MCP manager")
```

关键设计点：

- **条件初始化**：只有 `config.json` 中存在 `mcp` 字段时才初始化。这意味着 MCP 是完全可选的功能。
- **异常隔离**：MCP 初始化失败不会阻止应用启动。用 `try/except` 包裹，仅记录错误日志。
- **注入模式**：通过 `runner.set_mcp_manager()` 将 MCP 管理器注入到 Runner。Runner 在每次 `query_handler()` 调用时从 manager 获取最新的 client 列表（支持热重载）。

`MCPClientManager` 内部使用 `asyncio.Lock` 保护 `_clients` 字典，确保并发安全：

```python
class MCPClientManager:
    def __init__(self) -> None:
        self._clients: Dict[str, StdIOStatefulClient] = {}
        self._lock = asyncio.Lock()
```

#### 阶段 3: Channel 管理器初始化

```python
channel_manager = ChannelManager.from_config(
    process=make_process_from_runner(runner),
    config=config,
    on_last_dispatch=update_last_dispatch,
)
await channel_manager.start_all()
```

这是最复杂的初始化步骤，涉及 3 个关键函数：

**`make_process_from_runner(runner)`**：

```python
def make_process_from_runner(runner):
    return runner.stream_query
```

这个桥接函数将 Runner 的 `stream_query` 方法作为 Channel 的消息处理回调。每个 Channel 收到消息后的处理链：

```
Channel SDK 回调 → channel.enqueue(payload)
    → ChannelManager Queue (maxsize=1000)
    → 4 个 worker 并发消费
    → channel.build_agent_request_from_native(payload) → AgentRequest
    → process(request) = runner.stream_query(request)
    → runner.query_handler() → CoPawAgent 执行
    → channel.send(response) → 发送回原平台
```

**`ChannelManager.from_config()`**：

```python
@classmethod
def from_config(cls, process, config, on_last_dispatch=None):
    available = get_available_channels()   # COPAW_ENABLED_CHANNELS 过滤
    ch = config.channels                   # Pydantic ChannelConfig 模型
    channels = []
    for key, ch_cls in get_channel_registry().items():
        if key not in available:
            continue
        ch_cfg = getattr(ch, key, None)    # 获取每个 channel 的配置
        if ch_cfg is None:
            continue
        channels.append(ch_cls.from_config(process, ch_cfg, ...))
    return cls(channels)
```

工作流程：
1. `get_available_channels()` 从 `COPAW_ENABLED_CHANNELS` 环境变量获取允许的频道列表
2. `get_channel_registry()` 返回内置 + 自定义频道的注册表
3. 为每个可用且有配置的频道调用 `from_config()` 创建实例

**`on_last_dispatch=update_last_dispatch`**：

```python
from ..config import update_last_dispatch
```

这是 Heartbeat 功能的关键回调。每当用户消息被处理并回复后，此回调记录最后一次交互的频道信息到 `config.json`，使 `HeartbeatTask` 的 `target="last"` 能知道该往哪个频道发送心跳消息。

**`channel_manager.start_all()`** 的内部流程：

```python
async def start_all(self) -> None:
    self._loop = asyncio.get_running_loop()  # 保存事件循环引用

    # 1. 为每个 channel 创建 Queue + enqueue 回调
    for ch in channels:
        self._queues[ch.channel] = asyncio.Queue(maxsize=1000)
        ch.set_enqueue(self._make_enqueue_cb(ch.channel))

    # 2. 为每个 channel 启动 4 个消费者 worker
    for ch in channels:
        for w in range(4):  # _CONSUMER_WORKERS_PER_CHANNEL = 4
            task = asyncio.create_task(
                self._consume_channel_loop(ch.channel, w)
            )
            self._consumer_tasks.append(task)

    # 3. 启动各 channel 的 SDK 连接
    for ch in channels:
        await ch.start()
```

为什么是 4 个 worker？因为同一个 channel 可能有多个不同 session 的消息需要并行处理。同一 session 的消息通过 debounce key + `_in_progress` 集合保证串行，不同 session 的消息由不同 worker 并行。

#### 阶段 4: Cron 管理器初始化

```python
repo = JsonJobRepository(get_jobs_path())      # ~/.copaw/jobs.json
cron_manager = CronManager(
    repo=repo,
    runner=runner,
    channel_manager=channel_manager,
    timezone="UTC",
)
await cron_manager.start()
```

`CronManager` 封装 APScheduler，核心依赖：

| 依赖 | 用途 |
|------|------|
| `repo` | 从 `jobs.json` 加载/持久化定时任务定义 |
| `runner` | 执行 `task_type="agent"` 类型的定时任务（需要 agent 推理） |
| `channel_manager` | 执行 `task_type="text"` 类型的定时任务（直接发送文本到频道） |

Cron 依赖 `channel_manager`，所以必须在 channel 启动之后才能启动。

#### 阶段 5: Chat 管理器初始化

```python
chat_repo = JsonChatRepository(get_chats_path())  # ~/.copaw/chats.json
chat_manager = ChatManager(repo=chat_repo)
runner.set_chat_manager(chat_manager)
```

`ChatManager` 管理聊天会话的元数据（不是消息内容）：
- 创建/更新聊天记录（session_id, user_id, channel, name, 时间戳）
- 由 `runner.query_handler()` 在每次请求时调用 `get_or_create_chat()` 和 `update_chat()`
- 持久化到 `chats.json`

#### 阶段 6: ConfigWatcher 启动

```python
config_watcher = ConfigWatcher(channel_manager=channel_manager)
await config_watcher.start()
```

`ConfigWatcher` 实现了 Channel 的热重载：

```
config.json 文件变更
    → ConfigWatcher._poll_loop() 每 2s 检测 mtime
    → mtime 变化 → 重新加载 config.json
    → _channels_hash() 快速比较 → channels 部分变化?
    → 逐个 channel diff → 哪个 channel 的配置改了?
    → old_channel.clone(new_config)
    → channel_manager.replace_channel(new_channel)
        → 启动新 channel → 替换列表中的旧 channel → 停止旧 channel
```

这使得用户在 Console UI 中修改频道配置后，无需重启即可生效。

#### 阶段 7: MCPConfigWatcher 启动

```python
mcp_watcher = None
if hasattr(config, "mcp"):
    try:
        mcp_watcher = MCPConfigWatcher(
            mcp_manager=mcp_manager,
            config_loader=load_config,
            config_path=get_config_path(),
        )
        await mcp_watcher.start()
    except Exception:
        logger.exception("Failed to start MCP watcher")
```

`MCPConfigWatcher` 的设计与 `ConfigWatcher` 平行但独立：

| 特性 | ConfigWatcher | MCPConfigWatcher |
|------|---------------|------------------|
| 监控目标 | `config.channels` 部分 | `config.mcp` 部分 |
| 轮询间隔 | 2 秒 | 2 秒 |
| 检测方式 | mtime + hash 双重检测 | mtime + hash 双重检测 |
| 重载方式 | `channel_manager.replace_channel()` | `mcp_manager.replace_client()` |
| 失败策略 | 保留旧快照，下次重试 | 跟踪失败次数，最多重试 3 次 |
| 重载模式 | 同步（阻塞轮询循环） | 异步（`asyncio.create_task` 后台执行） |

MCPConfigWatcher 的独特设计：
- **非阻塞重载**：MCP client 连接可能很慢（启动子进程），所以 reload 在后台 task 中执行，不阻塞轮询循环
- **重试限制**：`_client_failures` 字典跟踪每个 client 的失败次数，同一配置最多重试 3 次后放弃。修改配置会重置计数器。

#### 阶段 8: 状态注入

```python
app.state.runner = runner
app.state.channel_manager = channel_manager
app.state.cron_manager = cron_manager
app.state.chat_manager = chat_manager
app.state.config_watcher = config_watcher
app.state.mcp_manager = mcp_manager
app.state.mcp_watcher = mcp_watcher
```

将 7 个核心组件注入到 FastAPI 的 `app.state`。所有路由通过 `request.app.state.xxx` 访问组件，避免全局变量和循环导入。

#### 关闭阶段

```python
try:
    yield
finally:
    # 关闭顺序: watchers → cron → channels → mcp → runner
    try:
        await config_watcher.stop()
    except Exception:
        pass
    if mcp_watcher:
        try:
            await mcp_watcher.stop()
        except Exception:
            pass
    try:
        await cron_manager.stop()
    finally:
        await channel_manager.stop_all()
        if mcp_manager:
            try:
                await mcp_manager.close_all()
            except Exception:
                pass
        await runner.stop()
```

关闭顺序的设计逻辑：

| 顺序 | 组件 | 原因 |
|------|------|------|
| 1 | ConfigWatcher | 先停止监控，防止在关闭过程中触发 channel 重载 |
| 2 | MCPConfigWatcher | 同上，防止在关闭过程中触发 MCP 重载 |
| 3 | CronManager | 停止新的定时任务触发 |
| 4 | ChannelManager | 停止接收新消息（cancel 所有 worker → 停止所有 channel SDK） |
| 5 | MCPClientManager | 关闭所有 MCP 子进程连接 |
| 6 | Runner | 最后关闭，因为 channel/cron 可能正在使用 runner 处理最后的请求 |

**关键容错设计**：每个 `stop()` 都用 `try/except` 包裹，一个组件关闭失败不会阻止后续组件的清理。`cron_manager.stop()` 使用 `try/finally` 确保即使 cron 关闭失败，channels 和 runner 仍会被关闭。

---

## 4. FastAPI 实例创建（第 141–146 行）

```python
app = FastAPI(
    lifespan=lifespan,
    docs_url="/docs" if DOCS_ENABLED else None,
    redoc_url="/redoc" if DOCS_ENABLED else None,
    openapi_url="/openapi.json" if DOCS_ENABLED else None,
)
```

- `lifespan=lifespan`：绑定上面定义的生命周期管理器
- `DOCS_ENABLED`：由 `COPAW_OPENAPI_DOCS` 环境变量控制（默认 `false`）。生产环境不暴露 API 文档，开发时设置 `COPAW_OPENAPI_DOCS=true` 启用 `/docs` 和 `/redoc`

---

## 5. 前端静态文件服务（第 149–232 行）

### 5.1 静态目录解析 `_resolve_console_static_dir()`

```python
def _resolve_console_static_dir() -> str:
    # 优先级 1：环境变量
    if os.environ.get(_CONSOLE_STATIC_ENV):
        return os.environ[_CONSOLE_STATIC_ENV]

    # 优先级 2：打包在 Python 包内的 console 目录
    pkg_dir = Path(__file__).resolve().parent.parent  # src/copaw/
    candidate = pkg_dir / "console"
    if candidate.is_dir() and (candidate / "index.html").exists():
        return str(candidate)

    # 优先级 3：当前工作目录下的 console 构建产物
    cwd = Path(os.getcwd())
    for subdir in ("console/dist", "console_dist"):
        candidate = cwd / subdir
        if candidate.is_dir() and (candidate / "index.html").exists():
            return str(candidate)

    # 兜底：返回默认路径（可能不存在）
    return str(cwd / "console" / "dist")
```

解析策略的优先级适配了 3 种运行场景：

| 场景 | 使用的路径 |
|------|-----------|
| Docker 或自定义部署 | `COPAW_CONSOLE_STATIC_DIR` 环境变量 |
| `pip install copaw` (PyPI) | `src/copaw/console/`（构建时打包进去的） |
| 开发环境（`copaw app`） | `./console/dist`（`npm run build` 的输出） |

### 5.2 路由挂载策略

```python
# 根路径 → 返回 index.html
@app.get("/")
def read_root():
    if _CONSOLE_INDEX and _CONSOLE_INDEX.exists():
        return FileResponse(_CONSOLE_INDEX)
    return {"message": "Hello World"}

# 特定静态资源（logo、icon）→ 独立路由
@app.get("/logo.png")
def _console_logo(): ...

@app.get("/copaw-symbol.svg")
def _console_icon(): ...

# /assets/* → StaticFiles 中间件
_assets_dir = _console_path / "assets"
if _assets_dir.is_dir():
    app.mount("/assets", StaticFiles(directory=str(_assets_dir)), name="assets")

# SPA fallback：所有未匹配路径 → index.html
@app.get("/{full_path:path}")
def _console_spa(full_path: str):
    if _CONSOLE_INDEX and _CONSOLE_INDEX.exists():
        return FileResponse(_CONSOLE_INDEX)
    raise HTTPException(status_code=404, detail="Not Found")
```

这实现了标准的 **SPA (Single Page Application) 服务模式**：

1. `/` → `index.html`
2. `/assets/xxx.js` → Vite 构建产物（哈希文件名，长期缓存）
3. `/logo.png`, `/copaw-symbol.svg` → 根目录静态资源
4. `/chat`, `/channels`, `/settings/models` 等前端路由 → 全部回退到 `index.html`，由 React Router 处理

**为什么 logo 和 icon 要单独路由而不用 StaticFiles?**

因为 `StaticFiles` 挂载在 `/assets` 下，而 `logo.png` 和 `copaw-symbol.svg` 在构建产物的根目录，不在 `assets/` 子目录中。同时，根目录不能整体挂载为 `StaticFiles`（会与 API 路由冲突），所以这几个文件用独立的 `@app.get` 路由处理。

**路由注册顺序很重要**：

```
1. @app.get("/")                    ← 精确匹配
2. @app.get("/api/version")         ← 精确匹配
3. app.include_router(api_router)   ← /api/* 前缀
4. app.include_router(agent_app)    ← /api/agent/* 前缀
5. @app.get("/logo.png")            ← 精确匹配
6. app.mount("/assets", ...)        ← /assets/* 前缀
7. @app.get("/{full_path:path}")    ← 通配 SPA fallback（最后注册）
```

FastAPI 按注册顺序匹配路由，`{full_path:path}` 会匹配所有路径，所以必须最后注册，否则会拦截 API 请求。

---

## 6. API 路由挂载（第 189–195 行）

```python
# CoPaw 自有 API
app.include_router(api_router, prefix="/api")

# AgentScope 标准 agent API
app.include_router(
    agent_app.router,
    prefix="/api/agent",
    tags=["agent"],
)
```

### CoPaw API 路由表（`/api/*`）

`api_router` 来自 `routers/__init__.py`，聚合了 12 个子路由：

| 子路由模块 | 前缀 | 功能 |
|-----------|------|------|
| `agent_router` | `/api/agent/*` | Agent 配置（persona, skills, tools） |
| `config_router` | `/api/config/*` | 全局配置 CRUD |
| `console_router` | `/api/console/*` | Console 推送消息（`push-messages` 轮询） |
| `cron_router` | `/api/cron/*` | 定时任务 CRUD + 手动触发 |
| `local_models_router` | `/api/local-models/*` | 本地模型管理（下载/删除） |
| `mcp_router` | `/api/mcp/*` | MCP 工具列表 + 配置 |
| `ollama_models_router` | `/api/ollama-models/*` | Ollama 模型管理 |
| `providers_router` | `/api/providers/*` | LLM 提供商 CRUD |
| `runner_router` | `/api/chats/*` | 聊天记录列表 + 删除 |
| `skills_router` | `/api/skills/*` | 技能管理（启用/禁用/安装） |
| `workspace_router` | `/api/workspace/*` | 工作目录文件管理 |
| `envs_router` | `/api/envs/*` | 环境变量 CRUD |

### AgentScope 标准 API（`/api/agent/*`）

`agent_app.router` 提供 AgentScope Runtime 的标准接口：

| 端点 | 功能 |
|------|------|
| `POST /api/agent/process` | 流式处理 agent 请求（SSE） |
| `GET /api/agent/sessions` | 列出会话 |
| `DELETE /api/agent/sessions/{id}` | 删除会话 |

Console 前端的聊天界面直接调用 `/api/agent/process` 发送消息并接收流式响应。

---

## 7. 组件交互关系图

```
                    ┌─────────────────────────┐
                    │    FastAPI (app)         │
                    │  app.state.* 注入 ──────── 所有路由通过 request.app.state 访问
                    └────────┬────────────────┘
                             │
              ┌──────────────┼──────────────────┐
              │              │                  │
      ┌───────▼───────┐ ┌───▼────┐ ┌───────────▼──────────┐
      │  api_router   │ │ agent  │ │ Static Files + SPA   │
      │  (12 子路由)   │ │ _app   │ │ (Console 前端)        │
      │  /api/*       │ │ router │ │ /, /assets, fallback │
      └───────────────┘ └───┬────┘ └──────────────────────┘
                            │
                    ┌───────▼───────────┐
                    │   AgentRunner     │
                    │ .stream_query()   │◄──────────────────────┐
                    │ .query_handler()  │                       │
                    └──┬────┬───────────┘                       │
                       │    │                                   │
          ┌────────────┘    └──────────────┐                    │
          │                                │                    │
  ┌───────▼──────────┐          ┌──────────▼──────────┐        │
  │  MemoryManager   │          │   ChatManager       │        │
  │  (ReMe-AI)       │          │ (chats.json CRUD)   │        │
  └──────────────────┘          └─────────────────────┘        │
                                                               │
                    ┌──────────────────┐                       │
                    │ ChannelManager   │───── process ──────────┘
                    │ .from_config()   │   (= runner.stream_query)
                    │ .start_all()     │
                    │ .replace_channel │◄──── ConfigWatcher (2s 轮询)
                    └──┬───────────────┘
                       │
      ┌────────┬───────┴────────┬──────────┬──────────┐
      │        │                │          │          │
  ┌───▼──┐ ┌──▼───┐ ┌─────────▼┐ ┌──────▼──┐ ┌────▼───┐
  │钉钉  │ │飞书  │ │ Discord  │ │  QQ    │ │iMessage│
  │      │ │      │ │          │ │        │ │        │
  └──────┘ └──────┘ └──────────┘ └────────┘ └────────┘

  ┌──────────────────┐           ┌──────────────────────┐
  │  CronManager     │           │  MCPClientManager    │
  │  (APScheduler)   │           │  (StdIO clients)     │
  │  runner + ch_mgr │           │                      │
  └──────────────────┘           │◄── MCPConfigWatcher  │
                                 │    (2s 轮询)          │
                                 └──────────────────────┘
```

---

## 8. 关键设计模式

### 8.1 依赖注入（app.state）

**问题**：路由需要访问 Runner、ChannelManager 等组件，但不能在模块顶层导入（循环依赖 + 组件需要异步初始化）。

**方案**：在 `lifespan()` 中创建组件并注入到 `app.state`，路由通过 `request.app.state.xxx` 按需访问。

```python
# lifespan 中
app.state.runner = runner
app.state.cron_manager = cron_manager

# 路由中
@router.post("/api/cron/jobs")
async def create_job(request: Request):
    cron_manager = request.app.state.cron_manager
    # ...
```

### 8.2 观察者模式（Watcher）

**问题**：用户通过 Console UI 修改 `config.json` 后，需要自动更新运行中的 Channel 和 MCP 连接。

**方案**：两个独立的 Watcher，各自轮询 `config.json` 的 mtime 和 hash。

```
config.json 变更 → mtime 变化 → 重新加载 → hash 比较 → diff → 仅重载变更的部分
```

两级检测（mtime + hash）避免不必要的完整解析：
- mtime 不变 → 跳过（最快路径）
- mtime 变化但 hash 相同 → 只是其他字段变了（如 `last_dispatch`），跳过
- hash 变化 → 逐项 diff，仅重载真正变化的 channel/client

### 8.3 容错隔离

整个 `lifespan()` 的设计原则是：**一个组件的失败不应阻止其他组件的正常运行**。

启动阶段：
- MCP 初始化失败 → 仅日志，应用继续（没有 MCP 工具而已）
- MCPConfigWatcher 启动失败 → 仅日志，MCP 热重载不可用但已有连接正常

关闭阶段：
- 每个 `stop()` 独立 `try/except`
- `cron_manager.stop()` 用 `try/finally` 确保后续清理执行

### 8.4 桥接模式（`make_process_from_runner`）

**问题**：Channel 需要一个 `ProcessHandler` 回调来处理消息，但不应直接依赖 `AgentRunner` 类。

**方案**：

```python
def make_process_from_runner(runner):
    return runner.stream_query
```

一行代码实现桥接：Channel 只知道"给一个 `AgentRequest`，返回流式消息"的协议，不知道背后是 `AgentRunner`。这使得 Channel 可以对接其他 Runner 实现。

### 8.5 队列 + Worker 池（ChannelManager）

**问题**：Channel SDK 的回调可能来自不同线程（如 DingTalk 的 WebSocket 回调线程），且同一用户的连续消息需要合并（debounce）。

**方案**：

```
SDK 线程 ──thread-safe──▶ enqueue() ──call_soon_threadsafe──▶ asyncio Queue
                                                                     │
                         4 个 asyncio worker ◀───── get() ───────────┘
                              │
                    drain_same_key() → 同一 session 的消息合并为 batch
                              │
                    _process_batch() → 一次性处理
```

`call_soon_threadsafe` 将线程安全的入队操作桥接到 asyncio 事件循环。`_in_progress` 集合 + `_pending` 字典确保正在处理的 session 的新消息不会被另一个 worker 抢走，而是等当前处理完后合并到下一批。

---

## 9. 启动/关闭时序

### 启动时序（严格顺序）

```
时间轴 ─────────────────────────────────────────────────────────────▶

[T0] runner.start()
     ├── .env 加载
     ├── SafeJSONSession 创建
     └── MemoryManager.start()
                 │
[T1] ───────────┘
     MCPClientManager.init_from_config()
     runner.set_mcp_manager()
                 │
[T2] ───────────┘
     ChannelManager.from_config()
     channel_manager.start_all()
     ├── 创建 Queue + workers
     ├── Console.start()
     ├── DingTalk.start() (stream 连接)
     ├── Feishu.start() (WebSocket 连接)
     ├── Discord.start() (bot 登录)
     └── ...
                 │
[T3] ───────────┘    ← Channels 必须先启动，因为 Cron 要用它们发消息
     CronManager.start()
     └── APScheduler 加载并调度任务
                 │
[T4] ───────────┘
     ChatManager 创建
     runner.set_chat_manager()
                 │
[T5] ───────────┘
     ConfigWatcher.start()    (2s 轮询)
     MCPConfigWatcher.start() (2s 轮询)
                 │
[T6] ───────────┘
     app.state.* 注入
                 │
[T7] yield ─── 应用运行中 ──────────────────────────▶
```

### 关闭时序（逆序 + 容错）

```
时间轴 ─────────────────────────────────────────────────────────────▶

[S0] config_watcher.stop()     ← 先停监控，防止关闭期间触发热重载
[S1] mcp_watcher.stop()
[S2] cron_manager.stop()       ← 停止新任务触发
[S3] channel_manager.stop_all()
     ├── cancel 所有 worker tasks
     ├── gather(tasks, return_exceptions=True)
     ├── 清空 queues
     └── channel.stop() (逆序)
[S4] mcp_manager.close_all()   ← 关闭 MCP 子进程
[S5] runner.stop()
     └── MemoryManager.close()
```

---

## 10. 常见修改场景

### 场景 1: 添加新的生命周期组件

如果需要在应用启动时初始化一个新组件（比如 WebhookServer）：

1. 在 `lifespan()` 的 `yield` 之前添加初始化代码
2. 将组件注入 `app.state`
3. 在 `finally` 块中添加关闭代码（用 `try/except` 包裹）
4. 注意初始化顺序（是否依赖其他组件）

### 场景 2: 添加新的 API 路由组

1. 创建 `src/copaw/app/routers/new_feature.py`
2. 在 `routers/__init__.py` 中导入并 `include_router`
3. 通过 `request.app.state.xxx` 访问需要的组件

### 场景 3: 修改 Channel 热重载逻辑

热重载逻辑在 `config/watcher.py` 的 `ConfigWatcher` 中，不在 `_app.py`。`_app.py` 只负责创建和启动 watcher。

### 场景 4: 调整关闭顺序

关闭顺序的原则：
- **依赖方被后关闭**：Runner 被 Channel 和 Cron 依赖，所以最后关闭
- **监控先关闭**：Watcher 最先关闭，防止在清理过程中触发不必要的重载
- **每一步都可独立失败**：用 `try/except` 或 `try/finally` 包裹

### 场景 5: 调试启动问题

- **MCP 连接失败**：检查 `config.json` 中的 `mcp.clients` 配置，以及对应的命令/路径是否正确
- **Channel 启动失败**：查看日志中 `failed to start channels=xxx` 的具体异常
- **静态文件 404**：确认 `npm run build` 已执行，或检查 `COPAW_CONSOLE_STATIC_DIR` 环境变量
- **API 文档不可用**：设置 `COPAW_OPENAPI_DOCS=true` 环境变量
