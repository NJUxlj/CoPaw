# CoPaw 项目架构文档

> 版本：基于当前代码库分析生成 | 日期：2026-03-02

---

## 目录

1. [项目概述](#1-项目概述)
2. [技术栈](#2-技术栈)
3. [整体架构](#3-整体架构)
4. [目录结构](#4-目录结构)
5. [核心模块详解](#5-核心模块详解)
   - 5.1 [Agent 核心层](#51-agent-核心层)
   - 5.2 [应用层（App Layer）](#52-应用层app-layer)
   - 5.3 [频道系统（Channels）](#53-频道系统channels)
   - 5.4 [Skills 系统](#54-skills-系统)
   - 5.5 [定时任务系统（Crons）](#55-定时任务系统crons)
   - 5.6 [MCP 集成](#56-mcp-集成)
   - 5.7 [配置管理](#57-配置管理)
   - 5.8 [LLM 提供商系统（Providers）](#58-llm-提供商系统providers)
   - 5.9 [本地模型支持](#59-本地模型支持)
   - 5.10 [记忆管理](#510-记忆管理)
   - 5.11 [Runner 与会话管理](#511-runner-与会话管理)
6. [API 接口设计](#6-api-接口设计)
7. [数据流](#7-数据流)
8. [数据存储方案](#8-数据存储方案)
9. [前端架构](#9-前端架构)
10. [CLI 系统](#10-cli-系统)
11. [部署方案](#11-部署方案)
12. [扩展机制](#12-扩展机制)

---

## 1. 项目概述

CoPaw 是一个**个人 AI 助手平台**，支持多频道接入、Skills 插件化扩展、本地模型运行和 MCP 协议集成。它以「本地优先、数据可控」为设计理念，允许用户通过钉钉、飞书、QQ、Discord、iMessage 等多种渠道与 AI 助手交互，同时提供 Web 控制台进行可视化管理。

**核心特性：**

| 特性 | 说明 |
|------|------|
| 多频道接入 | 支持 DingTalk、Feishu、QQ、Discord、iMessage、Console |
| Skills 扩展 | 插件化 Skills 系统，SKILL.md 格式定义，支持从 Hub 搜索安装 |
| 本地模型 | 支持 llama.cpp、Apple Silicon MLX 及 Ollama 后端 |
| 定时任务 | APScheduler 驱动的 Cron 任务 + 心跳机制 |
| MCP 协议 | 集成 Model Context Protocol 客户端，自动发现 MCP 工具 |
| 配置热重载 | 配置变更与 MCP 配置变更均无需重启服务 |
| Web 控制台 | React 18 + Ant Design 管理界面，可视化配置所有功能 |
| 双层记忆 | 短期对话上下文 + ReMe-AI 驱动的长期记忆，自动压缩 |

---

## 2. 技术栈

### 后端

| 技术 | 版本/说明 |
|------|-----------|
| Python | 3.10 ~ <3.14 |
| FastAPI | Web 框架，通过 agentscope-runtime 提供 REST API |
| AgentScope | 1.0.16.dev0，Agent 基础框架（ReActAgent） |
| AgentScope Runtime | 1.1.0，Agent 运行时（Runner、Session 管理） |
| Uvicorn | >=0.40.0，ASGI 服务器 |
| APScheduler | >=3.11.2 <4，定时任务调度 |
| Pydantic | 数据验证与序列化（Config、API 模型） |
| ReMe-AI | 0.3.0.0，长期记忆管理（语义检索） |
| Playwright | >=1.49.0，浏览器自动化 |
| Transformers | >=4.30.0，Tokenizer / Embedding 支持 |
| python-dotenv | >=1.0.0，环境变量管理 |

### 前端（Console）

| 技术 | 版本/说明 |
|------|-----------|
| React | 18，前端框架 |
| TypeScript | ~5.8.3，类型安全 |
| Vite | >=6.3.5，构建工具 |
| Ant Design | ^5.29.1，UI 组件库 |
| antd-style | ^3.7.1，CSS-in-JS |
| React Router | ^7.13.0，前端路由 |
| i18next | ^25.8.4，国际化 |
| ahooks | ^3.9.6，React Hooks 工具集 |
| @agentscope-ai/chat | ^1.1.50，聊天组件 |
| @agentscope-ai/design | ^1.0.14，设计主题 |
| @agentscope-ai/icons | ^1.0.46，图标库 |
| lucide-react | ^0.562.0，图标补充 |

### 频道集成 SDK

| 频道 | SDK |
|------|-----|
| 钉钉 | dingtalk-stream >=0.24.3 |
| 飞书 | lark-oapi >=1.5.3 |
| Discord | discord-py >=2.3 |
| QQ | 内置 WebSocket 实现 |
| iMessage | macOS 原生（SQLite 读取 + AppleScript 发送） |

### 可选本地模型后端

| 后端 | 说明 | 依赖 |
|------|------|------|
| llama.cpp | 跨平台（CPU/GPU） | llama-cpp-python >=0.3.0 |
| MLX | Apple Silicon（M 系列芯片） | mlx-lm >=0.10.0 |
| Ollama | 通过 Ollama API 调用本地模型 | 系统安装 Ollama |

---

## 3. 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                          用户侧（多频道入口）                          │
│  钉钉  │  飞书  │  QQ  │  Discord  │  iMessage  │  Web Console      │
└────────────────────────────┬────────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────────┐
│                       FastAPI 应用层                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  ┌──────────┐  │
│  │ChannelManager│  │  REST API    │  │CronManager │  │ MCP Mgr  │  │
│  │(频道管理器)   │  │(路由层)      │  │(定时任务)   │  │(MCP客户端)│  │
│  └──────┬───────┘  └──────────────┘  └─────┬──────┘  └──────────┘  │
│         │                                   │                        │
│  ┌──────▼───────────────────────────────────▼──────────────────┐    │
│  │                AgentRunner (运行器)                           │    │
│  │  SafeJSONSession │ ChatManager │ ConsolePushStore            │    │
│  └──────────────────────────┬───────────────────────────────────┘    │
│                              │                                       │
│  ┌───────────────────────────▼──────────────────────────────────┐    │
│  │                     ConfigWatcher                             │    │
│  │           config.json 热重载  │  MCPConfigWatcher             │    │
│  └───────────────────────────────────────────────────────────────┘    │
└────────────────────────────│────────────────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────────────┐
│                       CoPawAgent (ReAct Agent)                       │
│                                                                      │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────────┐  │
│  │ LLM 推理   │  │ 工具调用   │  │Skills 执行 │  │  记忆管理    │  │
│  │(Providers) │  │ (Toolkit)  │  │(SkillsSvc) │  │(MemoryMgr)   │  │
│  └────────────┘  └────────────┘  └────────────┘  └──────────────┘  │
│                                                                      │
│  ┌────────────┐  ┌────────────┐                                     │
│  │CommandHdlr │  │  Hooks     │                                     │
│  │(/compact..)│  │(bootstrap, │                                     │
│  └────────────┘  │ mem_compact)│                                     │
│                  └────────────┘                                      │
└─────────────────────────────────────────────────────────────────────┘
          │                │               │
   ┌──────▼──┐      ┌──────▼──┐    ┌──────▼───────┐
   │LLM 提供商│      │内置/自定义│    │Skills Hub    │
   │DashScope │      │Skills   │    │(在线技能仓库)│
   │OpenAI等  │      │(SKILL.md)│   │ClawHub/GitHub│
   │Ollama    │      └─────────┘    └──────────────┘
   │本地模型  │
   └──────────┘
```

---

## 4. 目录结构

```
CoPaw/
├── src/copaw/                    # Python 核心源码
│   ├── __init__.py               # 包初始化（懒加载 CoPawAgent）
│   ├── __version__.py            # 版本号定义
│   ├── __main__.py               # python -m copaw 入口
│   ├── constant.py               # 全局常量与路径定义
│   ├── agents/                   # Agent 核心实现
│   │   ├── __init__.py           # 懒加载入口（避免重量级导入）
│   │   ├── react_agent.py        # CoPawAgent 主类（继承 ReActAgent）
│   │   ├── command_handler.py    # 系统命令处理器 (/compact, /new 等)
│   │   ├── prompt.py             # PromptBuilder + PromptConfig
│   │   ├── model_factory.py      # 模型与 Formatter 创建（文件块支持）
│   │   ├── skills_manager.py     # SkillService（Skills CRUD + 同步）
│   │   ├── skills_hub.py         # Skills Hub 在线安装
│   │   ├── hooks/                # Agent 生命周期钩子
│   │   │   ├── bootstrap.py      # BootstrapHook（首次启动引导）
│   │   │   └── memory_compaction.py # MemoryCompactionHook（自动压缩）
│   │   ├── memory/               # 记忆管理模块
│   │   │   ├── copaw_memory.py   # CoPawInMemoryMemory（会话记忆 + 压缩摘要）
│   │   │   ├── memory_manager.py # MemoryManager（ReMe-AI 长期记忆）
│   │   │   └── agent_md_manager.py # AgentMdManager（MD 文件读写）
│   │   ├── tools/                # 内置工具集
│   │   │   ├── shell.py          # execute_shell_command
│   │   │   ├── file_io.py        # read_file / write_file / edit_file
│   │   │   ├── file_search.py    # grep_search / glob_search
│   │   │   ├── browser_control.py# browser_use（Playwright）
│   │   │   ├── desktop_screenshot.py # desktop_screenshot（mss）
│   │   │   ├── send_file.py      # send_file_to_user
│   │   │   ├── get_current_time.py # get_current_time
│   │   │   └── memory_search.py  # memory_search（条件注册）
│   │   ├── skills/               # 内置 Skills（SKILL.md 定义）
│   │   │   ├── browser_visible/SKILL.md
│   │   │   ├── cron/SKILL.md
│   │   │   ├── dingtalk_channel/SKILL.md
│   │   │   ├── docx/SKILL.md
│   │   │   ├── file_reader/SKILL.md
│   │   │   ├── himalaya/SKILL.md
│   │   │   ├── news/SKILL.md
│   │   │   ├── pdf/SKILL.md
│   │   │   ├── pptx/SKILL.md
│   │   │   └── xlsx/SKILL.md
│   │   ├── md_files/             # Agent 默认人设文件
│   │   │   ├── en/               # 英文模板
│   │   │   └── zh/               # 中文模板
│   │   └── utils/                # Agent 工具函数
│   │       ├── message_utils.py  # 文件/媒体块处理
│   │       ├── token_counter.py  # Token 计数
│   │       └── tool_sanitizer.py # 工具消息修正
│   ├── app/                      # FastAPI 应用层
│   │   ├── _app.py               # FastAPI 应用入口 + lifespan 生命周期
│   │   ├── download_task_store.py# 模型下载任务内存存储
│   │   ├── console_push_store.py # Console 推送消息内存存储
│   │   ├── channels/             # 频道连接器
│   │   │   ├── base.py           # BaseChannel 抽象基类
│   │   │   ├── schema.py         # ChannelAddress / ChannelType 类型
│   │   │   ├── registry.py       # 频道注册表（内置 + 自定义发现）
│   │   │   ├── manager.py        # ChannelManager（队列 + Worker 消费模型）
│   │   │   ├── renderer.py       # MessageRenderer + RenderStyle
│   │   │   ├── utils.py          # file_url_to_local_path 等工具
│   │   │   ├── console/          # Console 频道（Web UI 交互）
│   │   │   ├── dingtalk/         # 钉钉频道
│   │   │   │   ├── channel.py    # DingTalkChannel
│   │   │   │   ├── handler.py    # Stream 回调处理
│   │   │   │   ├── markdown.py   # DingTalk Markdown 转换
│   │   │   │   ├── content_utils.py
│   │   │   │   ├── constants.py
│   │   │   │   └── utils.py
│   │   │   ├── feishu/           # 飞书频道
│   │   │   │   ├── channel.py    # FeishuChannel（WebSocket）
│   │   │   │   ├── constants.py
│   │   │   │   └── utils.py
│   │   │   ├── discord_/         # Discord 频道
│   │   │   │   └── channel.py    # DiscordChannel
│   │   │   ├── imessage/         # iMessage 频道（macOS）
│   │   │   │   └── channel.py    # IMessageChannel（SQLite 轮询）
│   │   │   └── qq/               # QQ 频道
│   │   │       └── channel.py    # QQChannel（WebSocket + HTTP）
│   │   ├── crons/                # 定时任务
│   │   │   ├── manager.py        # CronManager（APScheduler 封装）
│   │   │   ├── executor.py       # CronExecutor（任务执行器）
│   │   │   ├── heartbeat.py      # 心跳任务（HEARTBEAT.md 驱动）
│   │   │   ├── models.py         # 数据模型（CronJobSpec 等）
│   │   │   ├── api.py            # API 路由
│   │   │   └── repo/
│   │   │       ├── base.py       # BaseJobRepository 抽象
│   │   │       └── json_repo.py  # JsonJobRepository（jobs.json）
│   │   ├── mcp/                  # MCP 客户端管理
│   │   │   ├── manager.py        # MCPClientManager（多客户端管理）
│   │   │   └── watcher.py        # MCPConfigWatcher（配置热重载）
│   │   ├── routers/              # API 路由定义
│   │   │   ├── __init__.py       # api_router 汇总
│   │   │   ├── agent.py          # /api/agent（工作文件 + 记忆文件）
│   │   │   ├── config.py         # /api/config（频道配置）
│   │   │   ├── providers.py      # /api/models（LLM 提供商）
│   │   │   ├── skills.py         # /api/skills（Skills CRUD）
│   │   │   ├── local_models.py   # /api/local-models（本地模型下载）
│   │   │   ├── ollama_models.py  # /api/ollama-models（Ollama 模型）
│   │   │   ├── mcp.py            # /api/mcp（MCP 服务管理）
│   │   │   ├── workspace.py      # /api/workspace（上传/下载工作空间）
│   │   │   ├── envs.py           # /api/envs（环境变量管理）
│   │   │   └── console.py        # /api/console（推送消息轮询）
│   │   └── runner/               # Agent 运行器
│   │       ├── runner.py         # AgentRunner（继承 agentscope-runtime Runner）
│   │       ├── session.py        # SafeJSONSession（跨平台文件名安全）
│   │       ├── manager.py        # ChatManager（聊天列表管理）
│   │       ├── models.py         # ChatSpec / ChatHistory 模型
│   │       ├── api.py            # /api/chats 路由
│   │       ├── utils.py          # make_process_from_runner 等
│   │       ├── query_error_dump.py # 错误转储（调试用）
│   │       └── repo/
│   │           ├── base.py       # BaseChatRepository 抽象
│   │           └── json_repo.py  # JsonChatRepository（chats.json）
│   ├── cli/                      # 命令行接口
│   │   ├── main.py               # CLI 入口（click 命令组）
│   │   ├── app_cmd.py            # copaw app（启动服务）
│   │   ├── init_cmd.py           # copaw init（初始化配置）
│   │   ├── channels_cmd.py       # copaw channels（频道管理）
│   │   ├── cron_cmd.py           # copaw cron（定时任务管理）
│   │   ├── skills_cmd.py         # copaw skills（Skills 管理）
│   │   ├── providers_cmd.py      # copaw models（模型提供商管理）
│   │   ├── clean_cmd.py          # copaw clean（清理工作目录）
│   │   ├── utils.py              # questionary 交互封装
│   │   └── http.py               # httpx CLI 客户端
│   ├── config/                   # 配置管理
│   │   ├── config.py             # Config Pydantic 模型
│   │   ├── utils.py              # 配置加载/保存工具
│   │   └── watcher.py            # ConfigWatcher 热重载（FSEvents/inotify）
│   ├── envs/                     # 环境变量管理
│   │   └── *.py                  # EnvManager（envs.json 读写）
│   ├── providers/                # LLM 提供商管理
│   │   ├── registry.py           # ProviderRegistry（内置 + 自定义提供商）
│   │   ├── store.py              # ProviderStore（providers.json 持久化）
│   │   ├── models.py             # ProviderConfig / ModelConfig 模型
│   │   └── ollama_manager.py     # OllamaModelManager（Ollama API 封装）
│   ├── local_models/             # 本地模型支持
│   │   ├── manager.py            # LocalModelManager
│   │   ├── registry.py           # 后端注册表
│   │   └── backends/
│   │       ├── llamacpp.py       # llama.cpp 后端
│   │       └── mlx.py            # MLX 后端
│   ├── tokenizer/                # Tokenizer 工具
│   └── utils/                    # 通用工具函数
│       └── logging.py            # ColorFormatter / SuppressPathAccessLogFilter
├── console/                      # React 前端控制台
│   ├── src/
│   │   ├── App.tsx               # 应用入口（BrowserRouter + ConfigProvider）
│   │   ├── main.tsx              # ReactDOM 渲染入口
│   │   ├── i18n.ts               # i18next 初始化
│   │   ├── api/                  # API 客户端封装
│   │   │   ├── config.ts         # 基础配置
│   │   │   ├── request.ts        # axios 请求封装
│   │   │   ├── types/            # TypeScript 类型定义
│   │   │   └── modules/          # 按模块分离的 API 调用
│   │   │       ├── agent.ts      # Agent API
│   │   │       ├── channel.ts    # 频道 API
│   │   │       ├── chat.ts       # 聊天 API
│   │   │       ├── console.ts    # Console 推送 API
│   │   │       ├── cronjob.ts    # 定时任务 API
│   │   │       ├── env.ts        # 环境变量 API
│   │   │       ├── localModel.ts # 本地模型 API
│   │   │       ├── mcp.ts        # MCP API
│   │   │       ├── ollamaModel.ts# Ollama 模型 API
│   │   │       ├── provider.ts   # 提供商 API
│   │   │       ├── skill.ts      # Skills API
│   │   │       └── workspace.ts  # 工作空间 API
│   │   ├── components/           # 公共 React 组件
│   │   │   ├── ConsoleCronBubble/# Cron 推送气泡
│   │   │   ├── LanguageSwitcher.tsx
│   │   │   └── MarkdownCopy/     # Markdown 渲染 + 复制
│   │   ├── layouts/              # 布局组件
│   │   │   ├── MainLayout/       # 主布局 + 路由表
│   │   │   ├── Sidebar.tsx       # 侧边栏导航
│   │   │   └── Header.tsx        # 顶部栏
│   │   ├── pages/                # 页面组件
│   │   │   ├── Chat/             # 聊天主界面
│   │   │   ├── Agent/            # Agent 配置组
│   │   │   │   ├── Config/       # Agent 运行配置
│   │   │   │   ├── Skills/       # Skills 管理
│   │   │   │   ├── Workspace/    # 工作文件 + 记忆文件编辑
│   │   │   │   └── MCP/          # MCP 服务管理
│   │   │   ├── Control/          # 运维控制组
│   │   │   │   ├── Channels/     # 频道配置
│   │   │   │   ├── Sessions/     # 会话管理
│   │   │   │   └── CronJobs/     # 定时任务管理
│   │   │   └── Settings/         # 设置组
│   │   │       ├── Models/       # 模型提供商 + 本地模型 + Ollama
│   │   │       └── Environments/ # 环境变量管理
│   │   ├── locales/              # i18n 国际化资源
│   │   │   ├── en.json           # 英文
│   │   │   └── zh.json           # 中文
│   │   ├── styles/               # 全局样式
│   │   └── utils/                # 工具函数
│   └── public/                   # 静态资源
├── website/                      # 文档网站
│   └── public/docs/              # 文档 Markdown 内容
├── deploy/                       # 部署相关配置
│   ├── Dockerfile                # 多阶段构建
│   ├── entrypoint.sh             # supervisord 启动脚本
│   └── config/
│       └── supervisord.conf.template # supervisord 模板
├── scripts/                      # 工具脚本
├── docs/                         # 本架构文档目录
├── pyproject.toml                # Python 项目配置
├── .flake8                       # flake8 配置
├── .pre-commit-config.yaml       # Pre-commit hooks
├── README.md                     # 英文说明
└── README_zh.md                  # 中文说明
```

---

## 5. 核心模块详解

### 5.1 Agent 核心层

**`CoPawAgent`**（继承 AgentScope 的 `ReActAgent`）是整个系统的智能核心。

#### 类定义

```python
class CoPawAgent(ReActAgent):
    def __init__(
        self,
        env_context: Optional[str] = None,
        enable_memory_manager: bool = True,
        mcp_clients: Optional[List[Any]] = None,
        memory_manager: MemoryManager | None = None,
        max_iters: int = 50,              # ReAct 最大迭代轮次
        max_input_length: int = 128 * 1024,  # 128K tokens 上下文上限
    )
```

#### 初始化流程

```
CoPawAgent.__init__()
├── 1. _create_toolkit()            → 注册内置工具到 Toolkit
├── 2. _register_skills(toolkit)    → 加载 active_skills/ 中的 Skills
├── 3. _build_sys_prompt()          → 从 md_files/ 构建系统提示词
├── 4. 创建 Model + Formatter       → model_factory.create_model_and_formatter()
│       └── 增强 Formatter: 文件块支持 + 工具消息修正
├── 5. _setup_memory_manager()      → 初始化长期记忆 + 注册 memory_search
├── 6. CommandHandler 初始化         → 绑定 /compact /new /clear 等命令
└── 7. _register_hooks()            → 注册 pre_reasoning 钩子
        ├── BootstrapHook            → 首次启动引导
        └── MemoryCompactionHook     → 自动上下文压缩
```

#### 懒加载机制

`agents/__init__.py` 使用 `__getattr__` 实现懒加载，CLI 导入时不会拉起 AgentScope、Playwright 等重量级依赖：

```python
def __getattr__(name):
    if name == "CoPawAgent":
        from .react_agent import CoPawAgent
        return CoPawAgent
    # ...
```

#### ReAct 推理循环

```
用户消息 → CoPawAgent.reply(msg)
              │
              ├── 1. 预处理：process_file_and_media_blocks_in_message(msg)
              │        └── 下载文件/媒体附件到本地
              │
              ├── 2. 命令检查：CommandHandler.is_command(query)
              │        └── 是命令 → handle_command() → 直接返回
              │
              └── 3. 委托父类：super().reply(msg)
                       │
                       ├── pre_reasoning hooks:
                       │   ├── BootstrapHook.__call__()
                       │   │     └── 首次对话时注入 BOOTSTRAP.md 引导
                       │   └── MemoryCompactionHook.__call__()
                       │         └── 检查 Token 用量 > 阈值时自动压缩
                       │
                       └── ReAct Loop (max_iters=50):
                            ├── Think: LLM 生成文本 + 工具调用
                            ├── Act:   Toolkit 执行工具函数
                            ├── Observe: 工具返回结果
                            └── Repeat / Final Answer
```

#### 系统命令

| 命令 | 处理方法 | 功能 |
|------|----------|------|
| `/compact` | `_process_compact` | 压缩对话上下文（触发 MemoryManager） |
| `/new` | `_process_new` | 新建空会话 |
| `/clear` | `_process_clear` | 清空当前会话 |
| `/history` | `_process_history` | 查看会话历史 |
| `/compact_str` | `_process_compact_str` | 查看压缩摘要 |
| `/await_summary` | `_process_await_summary` | 等待异步摘要完成 |

#### 内置工具集（Tools）

| 工具函数 | 文件 | 功能 |
|----------|------|------|
| `execute_shell_command` | `shell.py` | 执行终端命令 |
| `read_file` | `file_io.py` | 读取本地文件 |
| `write_file` | `file_io.py` | 写入本地文件 |
| `edit_file` | `file_io.py` | 编辑本地文件（精确替换） |
| `grep_search` | `file_search.py` | 正则搜索文件内容 |
| `glob_search` | `file_search.py` | Glob 模式搜索文件 |
| `browser_use` | `browser_control.py` | Playwright 浏览器自动化 |
| `desktop_screenshot` | `desktop_screenshot.py` | mss 截取屏幕图像 |
| `send_file_to_user` | `send_file.py` | 向用户发送文件 |
| `get_current_time` | `get_current_time.py` | 获取当前时间 |
| `memory_search` | `memory_search.py` | 语义检索长期记忆（条件注册） |

#### 生命周期钩子

| 钩子 | 触发时机 | 功能 |
|------|----------|------|
| `BootstrapHook` | `pre_reasoning` | 检查 `BOOTSTRAP.md` 是否存在且为首次对话，若是则将引导指令注入上下文 |
| `MemoryCompactionHook` | `pre_reasoning` | 当 Token 用量超过 `max_input_length × MEMORY_COMPACT_RATIO`（默认 0.7）时，保留最近 N 条消息（默认 3），压缩其余为摘要 |

钩子签名：

```python
async def __call__(self, agent, kwargs: dict[str, Any]) -> dict[str, Any] | None
```

#### 系统提示词构建

`PromptBuilder` 按 `PromptConfig` 定义的顺序加载 Markdown 文件并拼接：

```
加载顺序: AGENTS.md → SOUL.md → PROFILE.md
来源目录: working_dir/md_files/ (用户自定义优先)
回退目录: agents/md_files/en/ 或 agents/md_files/zh/ (内置模板)
```

### 5.2 应用层（App Layer）

**`_app.py`** 是 FastAPI 应用的入口，通过 `lifespan` 上下文管理器管理所有组件的生命周期。

#### 启动顺序

```
1. AgentRunner.start()                → 初始化 Agent 运行环境
2. MCPClientManager.init_from_config() → 建立 MCP 服务连接
3. ChannelManager.from_config()       → 构造频道实例
4. ChannelManager.start_all()         → 创建队列 + 启动 Worker + 启动频道
5. CronManager.start()               → 加载任务 + 启动 APScheduler
6. ChatManager 初始化                 → 绑定 Runner
7. ConfigWatcher.start()              → 启动 config.json 监听
8. MCPConfigWatcher.start()           → 启动 MCP 配置监听
```

#### 停止顺序（在 finally 块中反向执行）

```
1. ConfigWatcher.stop()
2. MCPConfigWatcher.stop()
3. CronManager.stop()
4. ChannelManager.stop_all()
5. MCPClientManager.close_all()
6. AgentRunner.stop()
```

#### App State 共享

通过 `app.state` 将核心组件注入 FastAPI 上下文，各路由通过 `request.app.state` 访问：

```python
app.state.runner          # AgentRunner
app.state.channel_manager # ChannelManager
app.state.cron_manager    # CronManager
app.state.chat_manager    # ChatManager
app.state.mcp_manager     # MCPClientManager
app.state.config_watcher  # ConfigWatcher
app.state.mcp_watcher     # MCPConfigWatcher
```

#### 辅助内存存储

| 存储 | 文件 | 用途 |
|------|------|------|
| `DownloadTaskStore` | `download_task_store.py` | 模型下载任务状态跟踪（llamacpp/mlx/ollama 共用） |
| `ConsolePushStore` | `console_push_store.py` | Console 频道推送消息缓存（Cron 结果、下载完成通知等） |

`ConsolePushStore` 限制：最多 500 条消息，超过 60 秒自动过期，前端通过 `/api/console/push-messages` 轮询获取。

### 5.3 频道系统（Channels）

频道系统采用**注册表 + 队列 + Worker** 模式，支持内置频道和自定义频道。

#### BaseChannel 抽象基类

```python
class BaseChannel(ABC):
    channel: ChannelType          # 频道类型标识符
    uses_manager_queue: bool = True  # 是否使用 Manager 的异步队列

    def __init__(self, process: ProcessHandler,
                 on_reply_sent: OnReplySent = None,
                 show_tool_details: bool = True)

    # 工厂方法
    @classmethod
    def from_config(cls, process, config, on_reply_sent, show_tool_details) -> Self

    # 消息处理
    def build_agent_request_from_native(self, native_payload) -> AgentRequest
    def resolve_session_id(self, sender_id, channel_meta) -> str
    async def consume_one(self, payload) -> None

    # 发送（子类实现）
    @abstractmethod
    async def send(self, to_handle, text, meta) -> None
    async def send_content_parts(self, to_handle, parts, meta) -> None
    async def send_event(self, *, user_id, session_id, event, meta) -> None

    # 消息防抖与合并
    _debounce_seconds: float
    def get_debounce_key(self, payload) -> str
    def merge_native_items(self, items) -> Any
    def merge_requests(self, requests) -> AgentRequest

    # 生命周期
    async def start(self) -> None
    async def stop(self) -> None
```

#### 频道注册表

```python
BUILTIN_CHANNELS = {
    "console":  ConsoleChannel,
    "dingtalk": DingTalkChannel,
    "feishu":   FeishuChannel,
    "qq":       QQChannel,
    "discord":  DiscordChannel,
    "imessage": IMessageChannel,
}
```

自定义频道从 `working/custom_channels/` 目录通过 `_discover_custom_channels()` 动态发现并注册。

可通过 `COPAW_ENABLED_CHANNELS` 环境变量筛选可用频道。

#### ChannelManager 队列消费模型

```
ChannelManager
├── 每频道 1 个 asyncio.Queue（maxsize=1000）
├── 每频道 4 个 Worker 协程消费队列
├── 线程安全入队 enqueue(channel_id, payload)
├── 消息防抖与合并（相同 session_id 的连续消息）
│   ├── _in_progress[key] 标记正在处理
│   └── _pending[key] 合并等待中的消息
└── 方法:
    ├── start_all()                → 创建队列 + 启动 Worker + 启动频道
    ├── stop_all()                 → 取消 Worker + 清空队列 + 停止频道
    ├── replace_channel(new)       → 热替换频道实例（配置变更时）
    ├── send_event(channel, ...)   → 向指定频道发送事件
    └── send_text(channel, ...)    → 向指定频道发送文本（Cron 用）
```

#### 各频道实现

| 频道 | 类 | 传输层 | 接收方式 | 发送方式 | 特殊说明 |
|------|-------|--------|----------|----------|----------|
| Console | `ConsoleChannel` | HTTP/SSE | API 请求 → 队列 | stdout + ConsolePushStore | 前端轮询推送消息 |
| 钉钉 | `DingTalkChannel` | dingtalk-stream | Stream 回调 → 队列 | sessionWebhook | 维护 webhook 存储；DingTalk Markdown 格式转换 |
| 飞书 | `FeishuChannel` | lark-oapi WebSocket | WS 消息 → 队列 | Open API 发送 | session_id 格式 `feishu:chat_id:<id>` 或 `feishu:open_id:<id>` |
| Discord | `DiscordChannel` | discord.py | `on_message` → 队列 | `channel.send()` | 异步事件驱动 |
| iMessage | `IMessageChannel` | macOS 原生 | 轮询 `~/Library/Messages/chat.db` | AppleScript 发送 | 仅 macOS 可用 |
| QQ | `QQChannel` | WebSocket + HTTP | WS OP_DISPATCH → 队列 | HTTP API | 需要维护心跳 (OP_HEARTBEAT) |

#### 消息渲染

`MessageRenderer` 根据 `RenderStyle` 将 Agent 输出转换为频道适配的格式：

```python
class RenderStyle:
    show_tool_details: bool    # 是否显示工具调用详情
    supports_markdown: bool    # 是否支持 Markdown
    supports_code_fence: bool  # 是否支持代码块
    use_emoji: bool            # 是否使用 emoji
```

#### 消息路由流

```
外部频道消息
    ↓
Channel.enqueue(native_payload)
    ↓
ChannelManager 异步队列
    ↓
Worker 消费 → Channel.consume_one(payload)
    ↓
build_agent_request_from_native(payload)
    ↓ (防抖 & 合并)
AgentRunner.stream_query(request)
    ↓
CoPawAgent.reply(messages)
    ↓
Channel.send_event(event) → 渲染 + 发送到外部频道
```

### 5.4 Skills 系统

Skills 是 CoPaw 的**插件扩展机制**，每个 Skill 以 **SKILL.md 文件**（而非代码）定义能力。

#### Skill 定义格式（SKILL.md）

```markdown
---
name: skill_name
description: "何时使用此 Skill 的说明..."
metadata:
  copaw:
    emoji: "🖥️"
    requires: {}
---

# Skill 标题

此处为 Markdown 格式的详细指令，将被注入 Agent 的上下文中。
Agent 在判断需要此能力时，自动引用这些指令。
```

#### Skill 目录结构

```
skills/<skill_name>/
├── SKILL.md          # 必需：YAML front matter + Markdown 指令
├── references/       # 可选：参考文档
├── scripts/          # 可选：辅助脚本
└── assets/           # 可选：资源文件
```

#### Skills 三层存储 & 同步

```
┌─────────────────────────────────┐
│ builtin skills                  │  src/copaw/agents/skills/
│ (内置 Skills，随代码分发)        │
└─────────┬───────────────────────┘
          │ sync_skills_to_working_dir()
          ▼
┌─────────────────────────────────┐
│ customized_skills               │  working_dir/customized_skills/
│ (用户创建/Hub 安装的 Skills)     │  同名自定义 Skill 覆盖内置
└─────────┬───────────────────────┘
          │ enable_skill() / disable_skill()
          ▼
┌─────────────────────────────────┐
│ active_skills                   │  working_dir/active_skills/
│ (Agent 实际加载的 Skills)        │  CoPawAgent 只从此目录加载
└─────────────────────────────────┘
```

#### SkillService（skills_manager.py）

| 方法 | 功能 |
|------|------|
| `list_all_skills()` | 列出 builtin + customized 所有 Skills |
| `list_available_skills()` | 列出 active_skills 中的 Skills |
| `create_skill(name, content, ...)` | 在 customized_skills 中创建 Skill |
| `enable_skill(name)` | 同步到 active_skills |
| `disable_skill(name)` | 从 active_skills 移除 |
| `delete_skill(name)` | 从 customized_skills 删除 |

#### Skills Hub（skills_hub.py）

支持多个在线 Skill 源：

| 源 | 说明 |
|----|------|
| ClawHub | 官方 Skills 仓库 |
| Skills.sh | 社区 Skills |
| GitHub | 直接从 GitHub 仓库安装 |
| SkillsMP | Skills 市场 |

```python
install_skill_from_hub(bundle_url, version, enable, overwrite)
```

#### 内置 Skills 列表

| Skill | 功能 |
|-------|------|
| `browser_visible` | 可视化浏览器操作（Playwright） |
| `cron` | 定时任务管理指令 |
| `dingtalk_channel` | 钉钉频道特有操作 |
| `docx` | Word 文档处理 |
| `file_reader` | 文件读取增强 |
| `himalaya` | 邮件客户端 |
| `news` | 新闻摘要获取 |
| `pdf` | PDF 文档处理 |
| `pptx` | PPT 处理 |
| `xlsx` | Excel 处理 |

### 5.5 定时任务系统（Crons）

#### 核心架构

```
CronManager
├── APScheduler (后端调度器)
│   └── 支持 cron 表达式
├── CronExecutor
│   ├── task_type == "text"  → ChannelManager.send_text()
│   └── task_type == "agent" → AgentRunner.stream_query() + send_event()
├── HeartbeatTask
│   ├── 解析 HEARTBEAT.md 获取心跳指令
│   ├── 默认间隔: 30m（通过 heartbeat_every 配置）
│   └── 目标: "main" (主频道) 或 "last" (最后活跃频道)
└── JsonJobRepository
    └── 持久化存储到 working_dir/jobs.json
```

#### 任务数据模型

```python
CronJobSpec:
    id: str                        # 任务 ID
    name: str                      # 任务名称
    enabled: bool                  # 是否启用
    schedule: ScheduleSpec         # 调度配置（cron 表达式 + 时区）
    task_type: "text" | "agent"    # 任务类型
    text: str | None               # text 模式的消息内容
    request: CronJobRequest | None # agent 模式的请求参数
    dispatch: DispatchSpec         # 分发配置（频道 + 目标用户）
    runtime: JobRuntimeSpec        # 运行参数（并发/超时/容错）
    meta: dict                     # 扩展元数据
```

#### 任务执行流

```
APScheduler 触发
    ↓
CronExecutor.execute(job: CronJobSpec)
    ↓
    ├── task_type == "text":
    │   └── ChannelManager.send_text(channel, user_id, session_id, text)
    │
    └── task_type == "agent":
        ├── AgentRunner.stream_query(request)
        │   └── CoPawAgent 执行推理
        └── ChannelManager.send_event(channel, user_id, session_id, event)
```

#### 心跳任务

```
HEARTBEAT.md (工作目录中的心跳指令文件)
    ↓
HeartbeatTask.run_heartbeat_once()
    ├── 读取 HEARTBEAT.md 内容作为 prompt
    ├── 通过 AgentRunner 执行
    └── 结果发送到 heartbeat_target 频道
        ├── "main"  → 主频道
        └── "last"  → 最后一次交互的频道（on_last_dispatch 回调）
```

### 5.6 MCP 集成

**MCP（Model Context Protocol）** 客户端管理器提供对外部 MCP 服务的接入。

```
MCPClientManager
├── init_from_config(config: MCPConfig)
│   └── 读取 MCP 服务配置，创建 StdIOStatefulClient 连接
├── get_clients() → 返回活跃的 MCP 客户端列表
├── replace_client(key, config, timeout)
│   └── 热替换单个 MCP 客户端
├── remove_client(key) → 移除 MCP 客户端
└── close_all() → 关闭所有连接

MCPConfigWatcher
├── poll_interval: 2.0s
├── 基于 mtime + hash 检测配置变更
├── 变更时在后台异步重载受影响的客户端
└── 每个客户端有重试限制
```

MCP 工具注册到 Agent 的流程：

```
MCPClientManager.get_clients()
    ↓
CoPawAgent.register_mcp_clients()
    ↓
toolkit.register_mcp_client(client)  # 对每个 MCP 客户端
    ↓
AgentScope 自动发现 MCP 服务暴露的工具列表
    ↓
工具可在 ReAct 循环中被 LLM 调用
```

### 5.7 配置管理

#### Config Pydantic 模型

`Config` 是系统的统一配置数据结构，定义在 `config/config.py` 中。

#### 配置文件体系

| 文件 | 内容 | 管理类 |
|------|------|--------|
| `config.json` | 主配置（频道设置、Agent 参数、心跳配置） | ConfigWatcher |
| `providers.json` | LLM 提供商及模型配置 | ProviderStore |
| `envs.json` | 环境变量（API Key 等，加密存储） | EnvManager |
| `jobs.json` | 定时任务持久化 | JsonJobRepository |
| `chats.json` | 聊天会话历史 | JsonChatRepository |

#### 配置热重载

```
ConfigWatcher (基于 FSEvents/inotify 文件系统事件)
    ↓ 检测到 config.json 变更
    ↓
重新加载 Config (Pydantic 验证)
    ↓
通知 ChannelManager:
    ├── 对比变更的频道配置
    ├── replace_channel(new_channel)  # 热替换变更的频道
    └── 无需重启服务

MCPConfigWatcher (轮询模式, 2s 间隔)
    ↓ 检测到 MCP 配置变更 (mtime + hash)
    ↓
MCPClientManager.replace_client(key, new_config)
    ↓
重新注册 MCP 工具到 Agent
```

### 5.8 LLM 提供商系统（Providers）

#### 架构

```
ProviderRegistry                     # 内置提供商注册表
├── DashScope (阿里云百炼)
├── OpenAI
├── 自定义 OpenAI 兼容提供商
└── 本地模型 (llama.cpp / MLX)

ProviderStore                        # 持久化层
├── 加载/保存 providers.json
├── 提供商 CRUD 操作
└── 活跃模型管理 (active model)

OllamaModelManager                   # Ollama 专用管理器
├── 列出本地 Ollama 模型
├── 拉取 (下载) 模型
├── 删除模型
└── 通过 DownloadTaskStore 跟踪下载进度
```

#### 模型选择流程

```
Web 控制台 / CLI 设置 active model
    ↓
ProviderStore 保存到 providers.json
    ↓
AgentRunner 创建 CoPawAgent 时读取 active model
    ↓
model_factory.create_model_and_formatter()
    ├── 根据 provider_id 匹配提供商
    ├── 创建对应的 LLM Client
    └── 增强 Formatter: 文件块支持 + 工具消息修正
```

### 5.9 本地模型支持

CoPaw 支持在本地运行大型语言模型，通过三种方式实现：

| 方式 | 平台 | 依赖 | 管理路由 |
|------|------|------|----------|
| llama.cpp | 跨平台（CPU/GPU） | llama-cpp-python >=0.3.0 | `/api/local-models` |
| MLX | Apple Silicon（M 系列芯片） | mlx-lm >=0.10.0 | `/api/local-models` |
| Ollama | 跨平台（需安装 Ollama） | 系统级 Ollama | `/api/ollama-models` |

#### 本地模型使用流程

```
copaw models --local            # 查看本地模型列表
copaw models download <model>   # 下载模型
    ↓
DownloadTaskStore 跟踪下载进度
    ↓
LocalModelManager.load(model)   # 加载模型到内存
    ↓
注册为 Provider，与云端 LLM 统一接口
    ↓
CoPawAgent 通过 Provider 接口调用（透明切换）
```

#### 下载任务状态机

```
PENDING → DOWNLOADING → COMPLETED
                ↓
             FAILED
                ↓
           CANCELLED
```

### 5.10 记忆管理

CoPaw 采用**双层记忆架构**：

#### 短期记忆（CoPawInMemoryMemory）

继承 AgentScope 的 `InMemoryMemory`，增加压缩摘要和消息标记过滤：

```python
class CoPawInMemoryMemory(InMemoryMemory):
    async def get_memory(
        mark=None,                    # 按标记过滤
        exclude_mark=COMPRESSED,      # 排除已压缩的消息
        prepend_summary=True,         # 是否在开头注入压缩摘要
    ) -> list[Msg]

    def get_compressed_summary() -> str  # 获取压缩摘要文本
    def state_dict() -> dict             # 序列化（持久化用）
    def load_state_dict(data) -> None    # 反序列化
```

#### 长期记忆（MemoryManager）

基于 ReMe-AI 实现：

```python
class MemoryManager(ReMeFb):
    # 存储后端: "auto" / "chroma" / "local"
    # 环境变量: MEMORY_STORE_BACKEND

    compact_memory()          # 压缩对话为长期记忆
    summary_memory()          # 生成对话摘要
    memory_search(query)      # 语义检索长期记忆
    memory_get()              # 获取记忆内容
    add_async_summary_task()  # 添加异步摘要任务
    await_summary_tasks()     # 等待所有异步摘要完成
```

#### 压缩触发机制

```
MemoryCompactionHook (pre_reasoning)
    ↓
计算当前 Token 用量
    ↓
超过阈值? (max_input_length × MEMORY_COMPACT_RATIO, 默认 0.7)
    ├── 否 → 跳过
    └── 是 ↓
        保留系统提示词 + 最近 N 条消息 (MEMORY_COMPACT_KEEP_RECENT, 默认 3)
        ↓
        MemoryManager.compact_memory(older_messages)
        ↓
        标记旧消息为 COMPRESSED
        ↓
        压缩摘要存入 _compressed_summary
        ↓
        下次 get_memory(prepend_summary=True) 时注入
```

#### 记忆文件存储

```
working_dir/
├── md_files/          # Agent 工作文件（系统人设、任务笔记）
│   ├── AGENTS.md      # Agent 行为指引
│   ├── SOUL.md        # Agent 人格设定
│   ├── PROFILE.md     # 用户画像
│   └── BOOTSTRAP.md   # 首次启动引导（BootstrapHook 使用）
└── memory/            # 长期记忆文件
    └── *.md           # ReMe-AI 管理的结构化记忆条目
```

#### 相关环境变量

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `COPAW_MEMORY_COMPACT_KEEP_RECENT` | 3 | 压缩时保留最近消息数 |
| `COPAW_MEMORY_COMPACT_RATIO` | 0.7 | 压缩触发阈值比例 |
| `ENABLE_MEMORY_MANAGER` | true | 是否启用长期记忆管理器 |
| `MEMORY_STORE_BACKEND` | auto | 记忆存储后端（auto/chroma/local） |

### 5.11 Runner 与会话管理

#### AgentRunner

继承 agentscope-runtime 的 `Runner`，负责管理 Agent 生命周期和查询处理：

```python
class AgentRunner(Runner):
    # 核心处理器
    query_handler(msgs, request, **kwargs)
        ├── load_session_state(session_id)
        ├── CoPawAgent.reply(msgs)         # 流式输出
        └── save_session_state(session_id)

    # 生命周期
    init_handler()
        ├── SafeJSONSession 初始化
        └── MemoryManager 初始化
    shutdown_handler()
        └── memory_manager.close()

    # 绑定
    set_chat_manager(chat_manager)
    set_mcp_manager(mcp_manager)
```

#### SafeJSONSession

继承 AgentScope 的 `JSONSession`，增加跨平台文件名安全处理：

```python
class SafeJSONSession(JSONSession):
    def sanitize_filename(name: str) -> str
        # 替换 \ / : * ? " < > | 为 --
        # 确保 Windows/macOS/Linux 兼容
```

#### ChatManager

管理聊天会话列表（不管理消息内容，消息由 Session 管理）：

```python
class ChatManager:
    list_chats(user_id, channel)        # 列出聊天
    get_chat(chat_id)                   # 获取聊天详情
    get_or_create_chat(session_id, ...) # 获取或创建聊天
    create_chat(spec)                   # 创建聊天
    update_chat(spec)                   # 更新聊天
    delete_chats(chat_ids)              # 删除聊天
    count_chats(...)                    # 统计聊天数
```

#### 错误转储

`query_error_dump.py` 提供 `write_query_error_dump(request, exc, locals_)` 方法，在 Agent 执行出错时将完整上下文（请求、异常栈、Agent 状态）写入临时 JSON 文件用于调试。

---

## 6. API 接口设计

所有 REST API 挂载在 `/api` 前缀下，由 FastAPI 路由层提供。

### 根路由

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/` | SPA 入口页面（有 console 时）或 `{"message": "Hello World"}` |
| GET | `/api/version` | 返回版本号 `{"version": "0.0.4b2"}` |

### Agent API — `/api/agent`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/agent/files` | 列出工作文件 |
| GET | `/api/agent/files/{name}` | 读取工作文件 |
| PUT | `/api/agent/files/{name}` | 写入工作文件 |
| GET | `/api/agent/memory` | 列出记忆文件 |
| GET | `/api/agent/memory/{name}` | 读取记忆文件 |
| PUT | `/api/agent/memory/{name}` | 写入记忆文件 |
| GET | `/api/agent/running-config` | 获取 Agent 运行配置 |
| PUT | `/api/agent/running-config` | 更新 Agent 运行配置 |

### 频道配置 API — `/api/config`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/config/channels` | 列出所有频道配置 |
| GET | `/api/config/channels/types` | 列出支持的频道类型 |
| PUT | `/api/config/channels` | 批量更新频道配置 |
| GET | `/api/config/channels/{name}` | 获取特定频道配置 |
| PUT | `/api/config/channels/{name}` | 更新特定频道配置 |

### 模型提供商 API — `/api/models`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/models` | 列出所有提供商 |
| PUT | `/api/models/{id}/config` | 配置提供商（API Key 等） |
| POST | `/api/models/custom-providers` | 创建自定义提供商（OpenAI 兼容） |
| DELETE | `/api/models/custom-providers/{id}` | 删除自定义提供商 |
| POST | `/api/models/{id}/models` | 添加模型到提供商 |
| DELETE | `/api/models/{id}/models/{model_id}` | 从提供商删除模型 |
| GET | `/api/models/active` | 获取当前激活的 LLM |
| PUT | `/api/models/active` | 设置激活的 LLM |

### Skills API — `/api/skills`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/skills` | 列出所有 Skills（builtin + customized） |
| GET | `/api/skills/available` | 列出当前激活的 Skills |
| GET | `/api/skills/hub/search` | 搜索 Hub 中的 Skills |
| POST | `/api/skills/hub/install` | 从 Hub 安装 Skill |
| POST | `/api/skills` | 创建本地 Skill |
| POST | `/api/skills/{name}/enable` | 启用 Skill |
| POST | `/api/skills/{name}/disable` | 禁用 Skill |
| POST | `/api/skills/batch-enable` | 批量启用 Skills |
| POST | `/api/skills/batch-disable` | 批量禁用 Skills |
| DELETE | `/api/skills/{name}` | 删除 Skill |
| GET | `/api/skills/{name}/files/{source}/{path}` | 读取 Skill 内部文件 |

### 聊天 API — `/api/chats`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/chats` | 列出聊天会话 |
| POST | `/api/chats` | 创建聊天会话 |
| GET | `/api/chats/{id}` | 获取聊天详情 |
| PUT | `/api/chats/{id}` | 更新聊天信息 |
| DELETE | `/api/chats/{id}` | 删除聊天 |
| POST | `/api/chats/batch-delete` | 批量删除聊天 |

### 定时任务 API — `/api/cron`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/cron/jobs` | 列出所有任务 |
| GET | `/api/cron/jobs/{id}` | 获取任务详情 |
| POST | `/api/cron/jobs` | 创建任务 |
| PUT | `/api/cron/jobs/{id}` | 更新任务 |
| DELETE | `/api/cron/jobs/{id}` | 删除任务 |
| POST | `/api/cron/jobs/{id}/pause` | 暂停任务 |
| POST | `/api/cron/jobs/{id}/resume` | 恢复任务 |
| POST | `/api/cron/jobs/{id}/run` | 立即执行（fire-and-forget） |
| GET | `/api/cron/jobs/{id}/state` | 获取任务运行状态（上次/下次执行时间等） |

### 本地模型 API — `/api/local-models`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/local-models` | 列出本地模型 |
| POST | `/api/local-models/download` | 下载模型 |
| GET | `/api/local-models/download-status` | 查询下载状态 |
| POST | `/api/local-models/cancel-download/{task_id}` | 取消下载 |
| DELETE | `/api/local-models/{model_id}` | 删除本地模型 |

### Ollama 模型 API — `/api/ollama-models`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/ollama-models` | 列出 Ollama 模型 |
| POST | `/api/ollama-models/download` | 拉取 Ollama 模型 |
| GET | `/api/ollama-models/download-status` | 查询拉取状态 |
| DELETE | `/api/ollama-models/download/{task_id}` | 取消拉取 |
| DELETE | `/api/ollama-models/{name}` | 删除 Ollama 模型 |

### MCP 服务 API — `/api/mcp`

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/mcp` | 列出所有 MCP 客户端 |
| GET | `/api/mcp/{key}` | 获取 MCP 客户端详情 |
| POST | `/api/mcp` | 创建 MCP 客户端 |
| PUT | `/api/mcp/{key}` | 更新 MCP 客户端 |
| PATCH | `/api/mcp/{key}/toggle` | 启用/禁用 MCP 客户端 |
| DELETE | `/api/mcp/{key}` | 删除 MCP 客户端 |

### 其他 API

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/api/workspace/download` | 下载工作空间（打包） |
| POST | `/api/workspace/upload` | 上传工作空间（恢复） |
| GET | `/api/envs` | 列出环境变量 |
| PUT | `/api/envs` | 批量保存环境变量 |
| DELETE | `/api/envs/{key}` | 删除环境变量 |
| GET | `/api/console/push-messages` | 轮询 Console 推送消息 |

---

## 7. 数据流

### 7.1 用户消息处理流

```
┌─────────┐     消息      ┌──────────────┐  enqueue  ┌──────────┐
│ 外部频道 │──────────────▶│ChannelManager│──────────▶│ 异步队列  │
└─────────┘               └──────────────┘           └────┬─────┘
                                                          │
                                               Worker 消费（4 并发/频道）
                                                          │
                                                  ┌───────▼──────────┐
                                                  │  防抖 & 消息合并   │
                                                  │(相同 session 合并) │
                                                  └───────┬──────────┘
                                                          │
                                              ┌───────────▼───────────┐
                                              │    AgentRunner         │
                                              │  load_session_state()  │
                                              └───────────┬───────────┘
                                                          │
                                              ┌───────────▼───────────┐
                                              │     CoPawAgent        │
                                              │    (ReAct Loop)       │
                                              └───────────┬───────────┘
                                              Think       │    Act
                                    ┌─────────────────────┼──────────────┐
                                    │                     │              │
                              ┌─────▼────┐         ┌─────▼────┐  ┌─────▼──┐
                              │LLM 推理  │         │ 工具调用  │  │Skills  │
                              └─────┬────┘         └─────┬────┘  └─────┬──┘
                                    │                    │             │
                              ┌─────▼────────────────────▼─────────────▼──┐
                              │            Observe（结果汇总）              │
                              └──────────────────────┬────────────────────┘
                                                     │
                                             ┌───────▼───────┐
                                             │  返回响应       │
                                             │save_session()  │
                                             └───────┬───────┘
                                                     │
                                          ┌──────────▼──────────┐
                                          │Channel.send_event() │
                                          │ → MessageRenderer   │
                                          │ → 外部频道发送       │
                                          └─────────────────────┘
```

### 7.2 定时任务执行流

```
APScheduler 触发
    ──▶ CronExecutor.execute(job)
          │
          ├── task_type == "text":
          │   └── ChannelManager.send_text(channel, user_id, text)
          │
          └── task_type == "agent":
              ├── AgentRunner.stream_query(request)
              │   └── CoPawAgent 推理
              └── ChannelManager.send_event(channel, user_id, event)
                  └── 若出错 → ConsolePushStore.append(error_msg)
```

### 7.3 配置热重载流

```
config.json 变更
    ──检测──▶ ConfigWatcher (FSEvents/inotify)
                ──解析──▶ Config Pydantic 模型
                ──对比──▶ 识别变更的频道配置
                ──通知──▶ ChannelManager.replace_channel()
                            ──停止旧频道──▶ 启动新频道实例

MCP 配置变更
    ──轮询──▶ MCPConfigWatcher (mtime + hash, 2s 间隔)
                ──对比──▶ 识别变更的 MCP 客户端
                ──通知──▶ MCPClientManager.replace_client()
                            ──关闭旧连接──▶ 建立新连接
                            ──重试限制──▶ 防止频繁失败
```

### 7.4 记忆压缩流

```
MemoryCompactionHook (pre_reasoning)
    ──计算──▶ 当前 Token 用量
    ──比较──▶ 阈值 = max_input_length × 0.7
    ──超过──▶ 保留最近 3 条消息
    ──压缩──▶ MemoryManager.compact_memory(older_msgs)
    ──标记──▶ 旧消息标记为 COMPRESSED
    ──存储──▶ 压缩摘要 → _compressed_summary
    ──注入──▶ 下次 get_memory() 时 prepend 摘要
```

---

## 8. 数据存储方案

CoPaw 采用**纯文件系统存储**，无需外部数据库。

### 存储目录结构

```
~/.copaw/  (或 COPAW_WORKING_DIR 指定的目录)
├── config.json           # 主配置（频道配置、Agent 参数、心跳设置）
├── providers.json        # LLM 提供商配置（内置 + 自定义 + 活跃模型）
├── envs.json             # 环境变量（含 API Key，敏感数据）
├── jobs.json             # 定时任务持久化
├── chats.json            # 聊天会话元数据
├── HEARTBEAT.md          # 心跳任务指令
├── md_files/             # Agent 工作文件（Markdown 人设 + 笔记）
│   ├── AGENTS.md         # Agent 行为指引
│   ├── SOUL.md           # Agent 人格设定
│   ├── PROFILE.md        # 用户画像
│   └── BOOTSTRAP.md      # 首次启动引导
├── memory/               # 长期记忆文件（ReMe-AI 管理）
│   └── *.md              # 结构化记忆条目
├── active_skills/        # 当前激活的 Skills
│   └── <skill_name>/
│       └── SKILL.md
├── customized_skills/    # 用户创建/Hub 安装的 Skills
│   └── <skill_name>/
│       └── SKILL.md
├── custom_channels/      # 用户自定义频道模块
│   └── <channel_name>.py
├── models/               # 下载的本地模型文件
│   └── <model_name>/
└── sessions/             # Session 状态序列化文件
    └── <sanitized_session_id>.json
```

### 写入策略

所有 JSON 文件采用**原子写入**（先写 `.tmp` 临时文件，再原子替换），避免写入中断导致数据损坏：

```python
def save_json(path, data):
    tmp_path = path.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(data))
    tmp_path.replace(path)  # 原子替换
```

### 存储特点

| 特点 | 说明 |
|------|------|
| 零依赖 | 无需安装数据库，开箱即用 |
| 可移植 | 工作目录可通过 `/api/workspace/download` 打包备份 |
| 可读性 | JSON + Markdown，人类可直接编辑 |
| 热重载 | 部分配置变更无需重启（ConfigWatcher + MCPConfigWatcher） |
| 单机优先 | 适合个人用户，非分布式场景 |
| 跨平台 | SafeJSONSession 确保文件名在所有 OS 上安全 |

---

## 9. 前端架构

Console 控制台是一个 **React 18 + TypeScript** 单页应用，使用 `@agentscope-ai/design` 提供的 bailianTheme 主题。

### 技术选型

| 层 | 技术 |
|----|------|
| 框架 | React 18 |
| 路由 | react-router-dom v7 (BrowserRouter) |
| UI 组件库 | Ant Design 5 + @agentscope-ai/design |
| 样式 | antd-style (CSS-in-JS) + Less |
| 状态管理 | React useState/useEffect + ahooks |
| 国际化 | i18next + react-i18next |
| 聊天组件 | @agentscope-ai/chat |
| HTTP 客户端 | 自封装 request 模块 |
| 构建工具 | Vite 6 |

### 页面路由

| 路径 | 页面 | 所属分组 |
|------|------|---------|
| `/chat` | Chat 聊天主界面 | — |
| `/channels` | 频道配置 | Control |
| `/sessions` | 会话管理 | Control |
| `/cron-jobs` | 定时任务管理 | Control |
| `/skills` | Skills 管理 | Agent |
| `/mcp` | MCP 服务管理 | Agent |
| `/workspace` | 工作文件/记忆文件编辑 | Agent |
| `/agent-config` | Agent 运行配置 | Agent |
| `/models` | 模型提供商 + 本地模型 + Ollama | Settings |
| `/environments` | 环境变量管理 | Settings |

默认路由 `/` 重定向到 `/chat`。

### API 客户端组织

```
api/
├── config.ts          # 基础 URL 配置
├── request.ts         # 请求封装（拦截器、错误处理）
├── index.ts           # 统一导出
├── types/             # TypeScript 类型定义（与后端 Pydantic 模型对应）
│   ├── agent.ts
│   ├── channel.ts
│   ├── chat.ts
│   ├── cronjob.ts
│   ├── env.ts
│   ├── mcp.ts
│   ├── provider.ts
│   ├── skill.ts
│   └── workspace.ts
└── modules/           # 按模块分离的 API 调用函数
    ├── agent.ts       # Agent 工作文件/记忆 API
    ├── channel.ts     # 频道配置 API
    ├── chat.ts        # 聊天会话 API
    ├── console.ts     # Console 推送消息 API
    ├── cronjob.ts     # 定时任务 API
    ├── env.ts         # 环境变量 API
    ├── localModel.ts  # 本地模型 API
    ├── mcp.ts         # MCP 服务 API
    ├── ollamaModel.ts # Ollama 模型 API
    ├── provider.ts    # 提供商 API
    ├── skill.ts       # Skills API
    └── workspace.ts   # 工作空间 API
```

### 页面组件模式

每个功能页面通常遵循以下结构：

```
pages/<Feature>/
├── index.tsx              # 页面主组件
├── use<Feature>.ts        # 自定义 Hook（数据获取 + 状态管理）
└── components/
    ├── index.ts           # 组件统一导出
    ├── <Feature>Card.tsx  # 卡片组件
    └── <Feature>Drawer.tsx # 抽屉表单组件
```

### 前端与后端通信

- **生产模式**：FastAPI 直接服务 `src/copaw/console/` 目录下的静态文件（构建时从 `console/dist/` 复制）
- **开发模式**：Vite Dev Server（端口 5173）+ FastAPI（端口 8088），Vite 配置代理转发 `/api/*` 到后端
- **Console 推送**：前端通过轮询 `/api/console/push-messages` 获取 Cron 结果等推送消息

---

## 10. CLI 系统

CoPaw 提供完整的命令行界面，基于 click（或类似框架）构建：

### 命令总览

| 命令 | 文件 | 功能 | 模式 |
|------|------|------|------|
| `copaw init` | `init_cmd.py` | 交互式初始化配置 | 本地 |
| `copaw app` | `app_cmd.py` | 启动 Web 服务 | 本地 |
| `copaw channels` | `channels_cmd.py` | 频道管理 | HTTP |
| `copaw models` | `providers_cmd.py` | LLM 提供商与模型管理 | HTTP |
| `copaw skills` | `skills_cmd.py` | Skills 管理 | HTTP |
| `copaw cron` | `cron_cmd.py` | 定时任务管理 | HTTP |
| `copaw clean` | `clean_cmd.py` | 清理工作目录 | 本地 |

**两种运行模式：**
- **本地模式**：`init`、`app`、`clean` 直接操作文件系统
- **HTTP 模式**：`channels`、`models`、`skills`、`cron` 通过 `httpx` 调用运行中的 FastAPI API，需要服务已启动

### CLI 辅助工具

| 工具 | 文件 | 功能 |
|------|------|------|
| `prompt_confirm` | `cli/utils.py` | 交互式确认（questionary） |
| `prompt_choice` | `cli/utils.py` | 交互式选择 |
| `prompt_checkbox` | `cli/utils.py` | 交互式多选 |
| `client(base_url)` | `cli/http.py` | httpx 客户端（自动加 `/api` 前缀） |
| `print_json(data)` | `cli/http.py` | JSON 美化输出 |

---

## 11. 部署方案

### Docker 部署（推荐）

#### 多阶段 Dockerfile

```
Stage 1: console-builder (Node.js 镜像)
    ├── COPY console/
    ├── npm ci --include=dev
    └── npm run build → dist/

Stage 2: runtime (Python + Chromium)
    ├── 安装系统依赖
    │   ├── Python3 + venv
    │   ├── Chromium + 依赖库（浏览器自动化）
    │   ├── Xvfb + XFCE4（虚拟桌面，支持 desktop_screenshot）
    │   ├── supervisor（进程管理）
    │   └── 中文字体（wqy-zenhei, wqy-microhei）
    ├── pip install . (copaw 包)
    ├── COPY --from=console-builder dist/ → src/copaw/console/
    ├── copaw init --defaults --accept-security
    └── EXPOSE 8088
```

#### supervisord 进程管理

Docker 容器内通过 supervisord 同时运行多个进程：

| 进程 | 优先级 | 功能 |
|------|--------|------|
| `dbus` | 默认 | D-Bus 系统总线（XFCE4 依赖） |
| `xvfb` | 10 | 虚拟帧缓冲（`:1`, 1280x800x24） |
| `xfce4` | 20 | XFCE4 桌面环境（浏览器操作和截图用） |
| `app` | 30 | `copaw app --host 0.0.0.0 --port $COPAW_PORT` |

#### Docker 运行

```bash
# 基本运行
docker run -p 8088:8088 -v copaw-data:/app/working agentscope/copaw:latest

# 带环境变量
docker run -p 8088:8088 \
  -e DASHSCOPE_API_KEY=your_key \
  -e COPAW_PORT=8088 \
  -e COPAW_ENABLED_CHANNELS="dingtalk,feishu,qq,console" \
  -v copaw-data:/app/working \
  agentscope/copaw:latest
```

#### Docker 环境默认配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `COPAW_WORKING_DIR` | `/app/working` | 工作目录 |
| `COPAW_PORT` | `8088` | 服务端口（通过 entrypoint.sh 注入 supervisord） |
| `COPAW_ENABLED_CHANNELS` | `dingtalk,feishu,qq,console` | 可用频道（不含 imessage/discord） |
| `DISPLAY` | `:1` | 虚拟显示器（Xvfb 提供） |

### 本地开发

```bash
# 安装依赖
pip install -e ".[dev]"

# 初始化配置
copaw init

# 启动服务
copaw app --host 0.0.0.0 --port 8088

# 前端开发（另一个终端）
cd console && npm ci && npm run dev
```

### PyPI 安装

```bash
pip install copaw
copaw init --defaults
copaw app
```

---

## 12. 扩展机制

### 12.1 自定义频道

在 `working/custom_channels/` 目录下创建 Python 文件，实现 `BaseChannel` 接口即可自动被发现和加载。

```python
from copaw.app.channels.base import BaseChannel

class MyChannel(BaseChannel):
    channel = "my_channel"

    async def send(self, to_handle, text, meta):
        # 发送消息到你的平台
        ...

    async def start(self):
        # 启动连接
        ...
```

注册表在启动时自动从 `CUSTOM_CHANNELS_DIR` 发现并合并到内置频道列表中。

### 12.2 自定义 Skills

两种方式创建 Skills：

**方式一：文件系统**

在 `working/customized_skills/<skill_name>/` 下创建 `SKILL.md`，包含 YAML front matter 和 Markdown 指令。

**方式二：Web 控制台 / API**

通过 `POST /api/skills` 或 Web 控制台可视化创建。

Skills 创建后需通过 `enable_skill()` 激活（同步到 `active_skills/`），Agent 才会加载。

### 12.3 自定义 LLM 提供商

通过 `/api/models/custom-providers` 接口或 Web 控制台添加兼容 OpenAI 接口的自定义提供商。支持配置：

- `base_url`：API 端点
- `api_key`：认证密钥
- 自定义模型列表

### 12.4 MCP 服务扩展

通过 Web 控制台或 `/api/mcp` 接口配置 MCP 服务端点。MCPConfigWatcher 自动检测配置变更并热重载。Agent 自动发现 MCP 服务暴露的工具并纳入 ReAct 循环可调用的工具集。

### 12.5 工作空间迁移

通过 `/api/workspace/download` 导出完整工作空间（打包为压缩文件），通过 `/api/workspace/upload` 导入恢复，实现配置和数据的跨机器迁移。

---

## 附录：全局常量

| 常量 | 来源 | 默认值 |
|------|------|--------|
| `WORKING_DIR` | `COPAW_WORKING_DIR` | `~/.copaw` |
| `CONFIG_FILE` | `COPAW_CONFIG_FILE` | `config.json` |
| `JOBS_FILE` | `COPAW_JOBS_FILE` | `jobs.json` |
| `CHATS_FILE` | `COPAW_CHATS_FILE` | `chats.json` |
| `HEARTBEAT_FILE` | `COPAW_HEARTBEAT_FILE` | `HEARTBEAT.md` |
| `HEARTBEAT_DEFAULT_EVERY` | — | `"30m"` |
| `HEARTBEAT_DEFAULT_TARGET` | — | `"main"` |
| `ACTIVE_SKILLS_DIR` | — | `WORKING_DIR/active_skills` |
| `CUSTOMIZED_SKILLS_DIR` | — | `WORKING_DIR/customized_skills` |
| `MEMORY_DIR` | — | `WORKING_DIR/memory` |
| `CUSTOM_CHANNELS_DIR` | — | `WORKING_DIR/custom_channels` |
| `MODELS_DIR` | — | `WORKING_DIR/models` |
| `LOG_LEVEL` | `COPAW_LOG_LEVEL` | `info` |
| `DOCS_ENABLED` | `COPAW_OPENAPI_DOCS` | `false` |
| `MEMORY_COMPACT_KEEP_RECENT` | `COPAW_MEMORY_COMPACT_KEEP_RECENT` | `3` |
| `MEMORY_COMPACT_RATIO` | `COPAW_MEMORY_COMPACT_RATIO` | `0.7` |

---

*本文档基于源码分析生成，如有遗漏请参考源码及官方文档（`website/public/docs/`）。*
