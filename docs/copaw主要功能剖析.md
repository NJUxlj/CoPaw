# CoPaw 核心功能剖析

本文档深入分析 CoPaw 项目的核心功能模块，包括功能描述、调用链分析和架构设计。

---

## 1. Agent 系统（智能体核心）

### 1.1 功能概述

Agent 系统是 CoPaw 的核心智能体实现，基于 ReAct（Reasoning + Acting）模式构建，集成了工具调用、技能管理、记忆管理和安全控制等功能。

**核心组件：**
- **CoPawAgent**: 主智能体类，继承自 ReActAgent
- **MemoryManager**: 记忆管理器，支持向量搜索和全文检索
- **Toolkit**: 工具集，包含内置工具和动态技能
- **ToolGuard**: 工具调用安全拦截层

### 1.2 调用链分析

```
用户请求
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  ChannelManager (渠道管理器)                                  │
│  - 接收来自各渠道的消息                                        │
│  - 调用 process handler 处理请求                              │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  AgentRunner (代理运行器)                                     │
│  - stream_query() 流式处理查询                                │
│  - 创建/获取 Agent 实例                                       │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  CoPawAgent (主智能体)                                        │
│  - __init__(): 初始化工具集、技能、记忆管理器                    │
│  - reply(): 处理用户输入                                      │
│  - 继承 ReActAgent 的 _reasoning() + _acting() 循环           │
└─────────────────────────────────────────────────────────────┘
    │
    ├──► Toolkit (工具集)
    │       ├── 内置工具: execute_shell_command, read_file, write_file...
    │       ├── 动态技能: 从 working_dir/skills 加载
    │       └── MCP 工具: 通过 MCP 客户端注册
    │
    ├──► MemoryManager (记忆管理)
    │       ├── 向量搜索: 基于 Embedding 的语义检索
    │       ├── 全文搜索: FTS (Full-Text Search)
    │       └── 记忆压缩: 自动压缩长对话历史
    │
    └──► ToolGuardMixin (安全拦截)
            ├── _reasoning(): 拦截推理过程
            ├── _acting(): 拦截工具调用
            └── 调用 ToolGuardEngine 进行安全检查
```

### 1.3 核心代码路径

| 组件 | 文件路径 |
|------|----------|
| CoPawAgent | `src/copaw/agents/react_agent.py` |
| MemoryManager | `src/copaw/agents/memory/memory_manager.py` |
| ToolGuardMixin | `src/copaw/agents/tool_guard_mixin.py` |
| ToolGuardEngine | `src/copaw/security/tool_guard/engine.py` |
| 内置工具 | `src/copaw/agents/tools/` |

### 1.4 关键流程详解

**初始化流程：**
```python
CoPawAgent.__init__()
    ├── _create_toolkit()          # 创建工具集，注册内置工具
    ├── _register_skills()         # 从 working_dir 加载技能
    ├── _build_sys_prompt()        # 构建系统提示词
    ├── _setup_memory_manager()    # 设置记忆管理器
    └── _register_hooks()          # 注册 Bootstrap 和记忆压缩钩子
```

**请求处理流程：**
```python
CoPawAgent.reply()
    ├── 预处理消息（文件、媒体块）
    ├── 调用父类 ReActAgent.reply()
    │       ├── _reasoning()      # ToolGuardMixin 拦截
    │       └── _acting()         # ToolGuardMixin 拦截
    └── 返回响应
```

---

## 2. Channel 系统（多渠道消息处理）

### 2.1 功能概述

Channel 系统负责对接各种消息渠道（钉钉、飞书、Discord、QQ 等），提供统一的消息收发接口。

**支持的渠道：**
- 钉钉 (DingTalk)
- 飞书 (Feishu/Lark)
- Discord
- QQ
- 企业微信 (WeCom)
- Matrix
- Mattermost
- 控制台 (Console)

### 2.2 调用链分析

```
外部消息（Webhook/WebSocket）
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  具体 Channel 实现类                                          │
│  - DingTalkChannel, FeishuChannel, DiscordChannel...         │
│  - 解析原生消息格式为 AgentRequest                            │
│  - 调用 enqueue() 将请求加入队列                              │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  ChannelManager (渠道管理器)                                  │
│  - 维护每个渠道的 asyncio.Queue                               │
│  - 启动消费者任务 _consumer_loop()                            │
│  - 批量合并同一会话的消息                                      │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  BaseChannel.consume_one() / _consume_one_request()           │
│  - 调用 process handler (AgentRunner.stream_query)            │
│  - 流式接收 Event 响应                                        │
│  - 调用 send_event() 发送回复                                 │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  具体 Channel 发送实现                                         │
│  - 将 Event 转换为渠道特定格式                                 │
│  - 调用渠道 API 发送消息                                       │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                      ChannelManager                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │   Queue     │  │   Queue     │  │   Queue     │          │
│  │  (钉钉)     │  │  (飞书)     │  │  (Discord)  │          │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          │
│         │                │                │                  │
│  ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐          │
│  │  Consumer   │  │  Consumer   │  │  Consumer   │          │
│  │   Workers   │  │   Workers   │  │   Workers   │          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
└─────────────────────────────────────────────────────────────┘
         │                │                │
         └────────────────┼────────────────┘
                          ▼
              ┌───────────────────────┐
              │    BaseChannel        │
              │  - consume_one()      │
              │  - send_event()       │
              │  - send_text()        │
              └───────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
┌─────────────────┐ ┌─────────────┐ ┌───────────────┐
│ DingTalkChannel │ │FeishuChannel│ │ DiscordChannel│
└─────────────────┘ └─────────────┘ └───────────────┘
```

### 2.4 核心代码路径

| 组件 | 文件路径 |
|------|----------|
| ChannelManager | `src/copaw/app/channels/manager.py` |
| BaseChannel | `src/copaw/app/channels/base.py` |
| 渠道注册表 | `src/copaw/app/channels/registry.py` |
| 钉钉渠道 | `src/copaw/app/channels/dingtalk/` |
| 飞书渠道 | `src/copaw/app/channels/feishu/` |
| Discord渠道 | `src/copaw/app/channels/discord_/` |

### 2.5 消息处理流程

**接收消息：**
```python
# 以钉钉为例
DingTalkChannel
    ├── webhook_handler()          # 接收 Webhook 回调
    ├── _parse_incoming()          # 解析钉钉消息格式
    ├── _to_agent_request()        # 转换为 AgentRequest
    └── enqueue()                  # 加入 ChannelManager 队列
```

**发送消息：**
```python
BaseChannel.send_event()
    ├── _render_event()            # 渲染 Event 为文本/图片
    ├── _send_reply_parts()        # 分段发送长消息
    └── 渠道特定发送方法 (send_text, send_image...)
```

---

## 3. Skill 系统（技能管理）

### 3.1 功能概述

Skill 系统允许用户扩展 Agent 的能力，通过编写自定义技能脚本来实现特定功能。技能支持热加载，无需重启服务。

**技能类型：**
- **内置技能**: 随代码发布，位于 `src/copaw/agents/skills/`
- **自定义技能**: 用户创建，位于 `working_dir/customized_skills/`
- **激活技能**: 当前启用的技能，位于 `working_dir/active_skills/`

### 3.2 调用链分析

```
Agent 初始化
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  CoPawAgent._register_skills()                                │
│  - 确保技能目录初始化 (ensure_skills_initialized)              │
│  - 遍历 available_skills                                      │
│  - 调用 toolkit.register_agent_skill() 注册每个技能            │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  SkillsManager / SkillService (API 层)                        │
│  - list_available_skills(): 列出所有可用技能                   │
│  - create_skill(): 创建新技能                                 │
│  - update_skill(): 更新技能                                   │
│  - delete_skill(): 删除技能                                   │
│  - toggle_skill(): 启用/禁用技能                              │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  技能同步机制                                                  │
│  - 内置技能 → active_skills (首次启动同步)                     │
│  - customized_skills → active_skills (用户自定义优先)          │
│  - _sync_skills_to_working_dir(): 执行同步                     │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 技能目录结构

```
working_dir/
├── active_skills/              # 激活的技能（实际加载）
│   ├── xlsx/                   # Excel 处理技能
│   │   ├── SKILL.md            # 技能描述文件
│   │   └── scripts/            # 技能脚本
│   ├── pdf/                    # PDF 处理技能
│   ├── docx/                   # Word 处理技能
│   └── pptx/                   # PPT 处理技能
│
└── customized_skills/          # 用户自定义技能
    └── my_skill/
        ├── SKILL.md
        └── scripts/
```

### 3.4 核心代码路径

| 组件 | 文件路径 |
|------|----------|
| SkillsManager | `src/copaw/agents/skills_manager.py` |
| SkillService (API) | `src/copaw/app/routers/skills.py` |
| 内置技能目录 | `src/copaw/agents/skills/` |

### 3.5 技能加载流程

```python
# Agent 启动时
CoPawAgent._register_skills()
    ├── ensure_skills_initialized()
    │       └── _sync_skills_to_working_dir()
    │               ├── 复制 builtin skills → active_skills
    │               └── 复制 customized skills → active_skills (覆盖)
    │
    ├── list_available_skills()   # 扫描 active_skills 目录
    └── toolkit.register_agent_skill(skill_dir)  # 逐个注册
```

---

## 4. Provider 系统（模型提供商管理）

### 4.1 功能概述

Provider 系统统一管理各种 LLM 提供商（OpenAI、Anthropic、Gemini、阿里云等），提供统一的模型调用接口。

**支持的提供商：**
- OpenAI / Azure OpenAI
- Anthropic (Claude)
- Google Gemini
- 阿里云 (DashScope / CodingPlan)
- ModelScope
- DeepSeek
- MiniMax
- Ollama (本地)
- llama.cpp (本地)
- MLX (本地, Apple Silicon)

### 4.2 调用链分析

```
Agent 初始化
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  create_model_and_formatter()                                 │
│  - 从配置中读取当前选中的 provider 和 model                   │
│  - 调用 ProviderManager 创建 ChatModel                        │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  ProviderManager (单例模式)                                   │
│  - get_instance(): 获取全局唯一实例                           │
│  - create_chat_model(): 根据 provider_id 创建对应模型          │
│  - 管理内置提供商和自定义提供商                               │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  具体 Provider 实现                                           │
│  - OpenAIProvider: OpenAI 兼容接口                            │
│  - AnthropicProvider: Claude API                              │
│  - GeminiProvider: Google Gemini                              │
│  - OllamaProvider: Ollama 本地服务                            │
│  - DefaultProvider: 本地模型 (llama.cpp / MLX)                │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  RetryChatModel (包装器)                                      │
│  - 包装实际 ChatModel                                         │
│  - 提供自动重试机制 (指数退避)                                 │
│  - 记录 Token 使用量                                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    ProviderManager                           │
│                     (Singleton)                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              内置提供商 (Built-in)                   │    │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ │    │
│  │  │  OpenAI  │ │Anthropic │ │  Gemini  │ │DeepSeek │ │    │
│  │  └──────────┘ └──────────┘ └──────────┘ └─────────┘ │    │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ │    │
│  │  │DashScope │ │ModelScope│ │ MiniMax  │ │ Ollama  │ │    │
│  │  └──────────┘ └──────────┘ └──────────┘ └─────────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              自定义提供商 (Custom)                   │    │
│  │         (用户通过 API/Console 添加)                  │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌───────────────────┐
                    │  RetryChatModel   │
                    │  (重试 + Token记录) │
                    └───────────────────┘
```

### 4.4 核心代码路径

| 组件 | 文件路径 |
|------|----------|
| ProviderManager | `src/copaw/providers/provider_manager.py` |
| Provider 基类 | `src/copaw/providers/provider.py` |
| OpenAIProvider | `src/copaw/providers/openai_provider.py` |
| AnthropicProvider | `src/copaw/providers/anthropic_provider.py` |
| GeminiProvider | `src/copaw/providers/gemini_provider.py` |
| OllamaProvider | `src/copaw/providers/ollama_provider.py` |
| RetryChatModel | `src/copaw/providers/retry_chat_model.py` |

### 4.5 模型创建流程

```python
# Agent 初始化时
create_model_and_formatter()
    ├── load_config()                    # 加载配置
    ├── ProviderManager.get_instance()   # 获取 ProviderManager
    ├── provider_manager.create_chat_model(provider_id, model_id)
    │       ├── 查找 Provider 实例
    │       ├── provider.create_chat_model()  # 创建具体模型
    │       └── 包装为 RetryChatModel
    └── create_formatter()               # 创建格式器
```

---

## 5. 其他重要子系统

### 5.1 Cron 定时任务系统

**功能：** 支持定时发送消息或执行 Agent 任务

**调用链：**
```
CronManager
    ├── JsonJobRepository (任务存储)
    ├── CronScheduler (调度器)
    └── CronExecutor (执行器)
            ├── task_type=text: 直接发送消息
            └── task_type=agent: 调用 AgentRunner.stream_query()
```

**核心文件：**
- `src/copaw/app/crons/manager.py`
- `src/copaw/app/crons/executor.py`
- `src/copaw/app/crons/scheduler.py`

### 5.2 Tool Guard 安全系统

**功能：** 拦截危险工具调用，提供审批机制

**调用链：**
```
ToolGuardMixin._acting()
    ├── ToolGuardEngine.guard()          # 安全检查
    │       ├── RuleBasedToolGuardian    # 基于规则的检查
    │       └── 其他自定义 Guardian
    ├── 如果危险: 进入审批流程
    │       └── ApprovalService.create_request()
    └── 如果安全: 执行工具调用
```

**核心文件：**
- `src/copaw/agents/tool_guard_mixin.py`
- `src/copaw/security/tool_guard/engine.py`
- `src/copaw/security/tool_guard/guardians/rule_guardian.py`

### 5.3 MCP (Model Context Protocol) 系统

**功能：** 支持外部工具服务通过 MCP 协议接入

**调用链：**
```
MCPClientManager
    ├── init_from_config()               # 从配置初始化客户端
    ├── StdIOStatefulClient              # 本地进程通信
    ├── HttpStatefulClient               # HTTP 远程通信
    └── toolkit.register_mcp_client()    # 注册工具到 Agent
```

**核心文件：**
- `src/copaw/app/mcp/manager.py`

---

## 6. 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户交互层 (Channels)                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │  钉钉    │ │  飞书    │ │ Discord  │ │   QQ     │ │  Console │           │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘           │
└───────┼────────────┼────────────┼────────────┼────────────┼─────────────────┘
        │            │            │            │            │
        └────────────┴────────────┴────────────┴────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ChannelManager                                     │
│                    (消息队列 + 消费者管理)                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            AgentRunner                                       │
│                     (Agent 生命周期管理)                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CoPawAgent                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  ReAct Loop (推理-行动循环)                                              ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 ││
│  │  │  _reasoning │───►│  ToolGuard  │───►│   _acting   │                 ││
│  │  └─────────────┘    └─────────────┘    └─────────────┘                 ││
│  │         ▲                                              │                ││
│  │         └──────────────────────────────────────────────┘                ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│         │                           │                           │           │
│         ▼                           ▼                           ▼           │
│  ┌─────────────┐            ┌─────────────┐            ┌─────────────┐     │
│  │   Toolkit   │            │   Memory    │            │   Skills    │     │
│  │  (内置工具)  │            │  (记忆管理)  │            │  (技能系统)  │     │
│  └─────────────┘            └─────────────┘            └─────────────┘     │
│         │                           │                           │           │
│         ▼                           ▼                           ▼           │
│  ┌─────────────┐            ┌─────────────┐            ┌─────────────┐     │
│  │    MCP      │            │   ReMeLight │            │  Skill FS   │     │
│  │ (外部工具)   │            │ (向量/全文)  │            │ (文件同步)   │     │
│  └─────────────┘            └─────────────┘            └─────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ProviderManager                                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │  OpenAI  │ │Anthropic │ │  Gemini  │ │DashScope │ │  Ollama  │           │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. 总结

CoPaw 采用模块化架构设计，核心功能包括：

1. **Agent 系统**: 基于 ReAct 模式的智能体核心，集成工具、技能和记忆
2. **Channel 系统**: 统一的多渠道消息处理框架，支持 10+ 种消息渠道
3. **Skill 系统**: 可扩展的技能机制，支持热加载和自定义开发
4. **Provider 系统**: 统一的模型提供商管理，支持云端和本地模型

各子系统通过清晰的接口解耦，便于扩展和维护。安全机制（Tool Guard）贯穿整个工具调用流程，确保系统安全性。
