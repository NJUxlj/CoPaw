# AgentRunner 架构剖析

## 1. 概述

AgentRunner 是 CoPaw 的核心 AI Agent 引擎，基于 **AgentScope** 框架构建的 ReAct（Reasoning + Acting）智能体。它集成了工具（Tools）、技能（Skills）、记忆管理（Memory）和安全防护（Tool Guard）等核心能力。

### 核心技术栈

- **AgentScope**: 多智能体编排框架，提供 ReActAgent 基类
- **ReMe**: 记忆管理引擎，支持向量搜索和全文检索
- **Click**: 命令行框架
- **Pydantic**: 数据验证

---

## 2. 核心类：CoPawAgent

**文件**: [react_agent.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/react_agent.py)

`CoPawAgent` 是整个 AgentRunner 的核心入口，继承自 `ToolGuardMixin` 和 `ReActAgent`：

```python
class CoPawAgent(ToolGuardMixin, ReActAgent):
```

### 2.1 类层次结构（MRO）

```
CoPawAgent
    │
    ├── ToolGuardMixin      # 安全拦截：敏感工具审批
    │       │
    │       └── ReActAgent  # AgentScope 的 ReAct 智能体基类
    │               │
    │               └── AgentBase  # 基础智能体
    │
    └── (CoPawAgent)         # 业务逻辑扩展
```

### 2.2 初始化流程

```python
def __init__(
    self,
    env_context: Optional[str] = None,
    enable_memory_manager: bool = True,
    mcp_clients: Optional[List[Any]] = None,
    memory_manager: MemoryManager | None = None,
    request_context: Optional[dict[str, str]] = None,
    max_iters: int = 50,
    max_input_length: int = 128 * 1024,
    namesake_strategy: NamesakeStrategy = "skip",
):
```

**初始化步骤**：

1. **创建工具包** (`_create_toolkit`)
2. **注册技能** (`_register_skills`)
3. **构建系统提示** (`_build_sys_prompt`)
4. **创建模型和格式化器** (`create_model_and_formatter`)
5. **初始化父类 ReActAgent**
6. **设置记忆管理器** (`_setup_memory_manager`)
7. **注册命令处理器** (`CommandHandler`)
8. **注册钩子** (`_register_hooks`)

---

## 3. 核心组件详解

### 3.1 工具系统（Tools）

**文件**: [tools/__init__.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/__init__.py)

#### 3.1.1 内置工具列表

| 工具 | 文件 | 功能 |
|------|------|------|
| `execute_shell_command` | [shell.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/shell.py) | 执行 Shell 命令 |
| `read_file` | [file_io.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/file_io.py) | 读取文件 |
| `write_file` | [file_io.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/file_io.py) | 写入文件 |
| `edit_file` | [file_io.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/file_io.py) | 编辑文件 |
| `grep_search` | [file_search.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/file_search.py) | 文本搜索 |
| `glob_search` | [file_search.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/file_search.py) | 文件模式匹配 |
| `browser_use` | [browser_control.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/browser_control.py) | 浏览器自动化 |
| `desktop_screenshot` | [desktop_screenshot.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/desktop_screenshot.py) | 桌面截图 |
| `view_image` | [view_image.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/view_image.py) | 查看图片 |
| `send_file_to_user` | [send_file.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/send_file.py) | 发送文件给用户 |
| `get_current_time` | [get_current_time.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/get_current_time.py) | 获取当前时间 |
| `set_user_timezone` | [get_current_time.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/get_current_time.py) | 设置时区 |
| `get_token_usage` | [get_token_usage.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/get_token_usage.py) | 获取 Token 使用量 |
| `create_memory_search_tool` | [memory_search.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tools/memory_search.py) | 创建记忆搜索工具 |

#### 3.1.2 工具注册机制

```python
def _create_toolkit(self, namesake_strategy: NamesakeStrategy = "skip") -> Toolkit:
    toolkit = Toolkit()
    
    # 从配置读取哪些工具启用
    config = load_config()
    enabled_tools = {
        name: tool_config.enabled
        for name, tool_config in config.tools.builtin_tools.items()
    }
    
    # 注册工具函数
    for tool_name, tool_func in tool_functions.items():
        if enabled_tools.get(tool_name, True):  # 默认启用
            toolkit.register_tool_function(
                tool_func,
                namesake_strategy=namesake_strategy,
            )
```

#### 3.1.3 Shell 命令执行流程

```
用户请求
    │
    ▼
execute_shell_command()
    │
    ├── asyncio.to_thread() → 后台线程执行
    │
    ├── subprocess.Popen() → 创建子进程
    │       │
    │       ├── Windows: cmd /D /S /C <cmd>
    │       └── Unix: bash -c <cmd>
    │
    ├── 超时控制 (默认 60s)
    │
    └── truncate_shell_output() → 截断输出
```

---

### 3.2 技能系统（Skills）

**文件**: [skills_manager.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/skills_manager.py)

#### 3.2.1 技能类型

| 类型 | 路径 | 说明 |
|------|------|------|
| Builtin | `copaw/agents/skills/` | 内置技能 |
| Customized | `~/.copaw/skills/customized/` | 用户自定义技能 |
| Active | `~/.copaw/skills/active/` | 激活的技能 |

#### 3.2.2 技能目录结构

```
skills/
├── browser_visible/
│   └── SKILL.md
├── cron/
│   └── SKILL.md
├── dingtalk_channel/
│   └── SKILL.md
├── docx/
│   ├── SKILL.md
│   └── scripts/
│       └── ...
├── file_reader/
│   └── SKILL.md
├── guidance/
│   └── SKILL.md
├── himalaya/
│   └── SKILL.md
├── news/
│   └── SKILL.md
├── pdf/
│   └── SKILL.md
├── pptx/
│   └── SKILL.md
└── xlsx/
    └── SKILL.md
```

#### 3.2.3 技能注册流程

```python
def _register_skills(self, toolkit: Toolkit) -> None:
    ensure_skills_initialized()
    working_skills_dir = get_working_skills_dir()
    available_skills = list_available_skills()
    
    for skill_name in available_skills:
        skill_dir = working_skills_dir / skill_name
        toolkit.register_agent_skill(str(skill_dir))
```

---

### 3.3 记忆管理系统（Memory）

**文件**: [memory/memory_manager.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/memory/memory_manager.py)

#### 3.3.1 MemoryManager 继承关系

```
MemoryManager
    │
    └── ReMeLight (from reme.reme_light)
            │
            ├── 记忆存储 (Chroma/Local)
            ├── 向量嵌入 (Embedding)
            └── 全文检索 (FTS)
```

#### 3.3.2 环境配置

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `EMBEDDING_API_KEY` | - | 嵌入服务 API Key |
| `EMBEDDING_BASE_URL` | DashScope URL | 嵌入服务地址 |
| `EMBEDDING_MODEL_NAME` | - | 嵌入模型名称 |
| `EMBEDDING_DIMENSIONS` | 1024 | 向量维度 |
| `FTS_ENABLED` | true | 启用全文搜索 |
| `MEMORY_STORE_BACKEND` | auto | 存储后端 (auto/chroma/local) |

#### 3.3.3 核心方法

```python
class MemoryManager(ReMeLight):
    async def compact_memory(messages, previous_summary) -> str
        """将消息压缩为摘要"""
    
    async def summary_memory(messages) -> str
        """生成记忆摘要"""
    
    def get_in_memory_memory() -> ReMeInMemoryMemory
        """获取内存中的记忆"""
```

---

### 3.4 命令处理器（Command Handler）

**文件**: [command_handler.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/command_handler.py)

#### 3.4.1 支持的命令

| 命令 | 功能 |
|------|------|
| `/compact` | 压缩记忆 |
| `/new` | 开始新对话 |
| `/clear` | 清除历史 |
| `/history` | 查看历史 |
| `/compact_str` | 显示压缩摘要 |
| `/await_summary` | 等待摘要完成 |
| `/message` | 发送消息 |

#### 3.4.2 处理流程

```python
class CommandHandler(ConversationCommandHandlerMixin):
    async def handle_command(self, query: str) -> Msg:
        if query == "/compact":
            return await self._process_compact(messages)
        elif query == "/new":
            return await self._process_new(messages)
        # ...
```

---

### 3.5 钩子系统（Hooks）

**文件**: [hooks/__init__.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/hooks/__init__.py)

#### 3.5.1 BootstrapHook

**文件**: [hooks/bootstrap.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/hooks/bootstrap.py)

首次交互时检查 `BOOTSTRAP.md` 并引导用户完成初始化：

```python
class BootstrapHook:
    async def __call__(self, agent, kwargs) -> None:
        # 1. 检查 .bootstrap_completed 标志
        # 2. 读取 BOOTSTRAP.md
        # 3. 追加引导文本到首条用户消息
        # 4. 创建 .bootstrap_completed 标志
```

#### 3.5.2 MemoryCompactionHook

**文件**: [hooks/memory_compaction.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/hooks/memory_compaction.py)

自动压缩记忆以避免上下文窗口溢出：

```python
class MemoryCompactionHook:
    async def __call__(self, agent, kwargs) -> None:
        # 1. 计算当前 token 数
        # 2. 检查是否超过阈值
        # 3. 触发 compact_memory
        # 4. 更新压缩摘要
```

---

### 3.6 安全防护（Tool Guard）

**文件**: [tool_guard_mixin.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/tool_guard_mixin.py)

#### 3.6.1 拦截流程

```
_tool_call
    │
    ▼
ToolGuardMixin._acting()
    │
    ├── 1. 检查工具是否在 denied_tools → 自动拒绝
    │
    ├── 2. 检查工具是否在 guarded_tools
    │       │
    │       ├── 检查 session 预审批 (consume_approval)
    │       │
    │       └── 运行 ToolGuardEngine.guard()
    │               │
    │               └── 如果有 findings → 进入审批流程
    │
    └── 3. 正常执行 super()._acting()
```

#### 3.6.2 审批流程

```python
async def _acting_with_approval(self, tool_call, tool_name, result):
    # 1. 记录 findings 到日志
    # 2. 返回待审批状态
    # 3. 用户响应后调用 consume_approval 或 cancel_approval
```

---

### 3.7 模型工厂（Model Factory）

**文件**: [model_factory.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/model_factory.py)

#### 3.7.1 模型-格式化器映射

| 模型类 | 格式化器类 |
|--------|------------|
| `OpenAIChatModel` | `OpenAIChatFormatter` |
| `AnthropicChatModel` | `AnthropicChatFormatter` |
| `GeminiChatModel` | `GeminiChatFormatter` |

#### 3.7.2 FileBlockSupportFormatter

扩展原生格式化器以支持文件块（用于工具返回文件）：

```python
class FileBlockSupportFormatter(base_formatter_class):
    async def _format(self, msgs):
        # 1. 清理工具消息
        # 2. 处理 thinking 块
        # 3. 处理 extra_content (Gemini thought_signature)
        # 4. 注入 reasoning_content
```

---

### 3.8 提示词构建（Prompt）

**文件**: [prompt.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/agents/prompt.py)

#### 3.8.1 系统提示组成

| 文件 | 内容 |
|------|------|
| `AGENTS.md` | 工作流、规则和指南 |
| `SOUL.md` | 核心身份和行为原则 |
| `PROFILE.md` | Agent 身份和用户配置 |

#### 3.8.2 构建流程

```python
def build_system_prompt_from_working_dir() -> str:
    # 1. 读取配置中的 system_prompt_files
    # 2. 按顺序加载 AGENTS.md, SOUL.md, PROFILE.md
    # 3. 跳过不存在的文件
    # 4. 合并返回
```

---

## 4. 模块调用关系图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CoPawAgent                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │                        初始化阶段 (__init__)                        │     │
│  │                                                                       │     │
│  │   1. _create_toolkit() ──────────▶ Toolkit (内置工具)                │     │
│  │   2. _register_skills() ─────────▶ Skills (动态加载)                 │     │
│  │   3. _build_sys_prompt() ────────▶ System Prompt                     │     │
│  │   4. create_model_and_formatter()─▶ ChatModel + Formatter            │     │
│  │   5. _setup_memory_manager() ────▶ MemoryManager                      │     │
│  │   6. CommandHandler() ───────────▶ 命令处理器                         │     │
│  │   7. _register_hooks() ─────────▶ Hooks (Bootstrap/MemoryCompact)   │     │
│  │                                                                       │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │                        运行时阶段 (reply)                             │     │
│  │                                                                       │     │
│  │   用户消息                                                            │     │
│  │       │                                                               │     │
│  │       ▼                                                               │     │
│  │   process_file_and_media_blocks_in_message()                         │     │
│  │       │                                                               │     │
│  │       ▼                                                               │     │
│  │   command_handler.is_command()                                       │     │
│  │       │                                                               │     │
│  │       ├── Yes ───▶ handle_command() ──────────────────────────────▶│     │
│  │       │        │                                                      │     │
│  │       │        ├── /compact ───▶ _process_compact()                  │     │
│  │       │        ├── /new ───────▶ _process_new()                      │     │
│  │       │        ├── /clear ─────▶ _process_clear()                    │     │
│  │       │        └── ...                                                 │     │
│  │       │                                                               │     │
│  │       └── No ───▶ super().reply()                                     │     │
│  │                    │                                                  │     │
│  │                    ▼                                                  │     │
│  │               _reasoning() ───────────────────────────────────────┐   │     │
│  │                    │                                           │   │     │
│  │                    │  ┌─ pre_reasoning hooks ──────────────┐   │   │     │
│  │                    │  │                                     │   │   │     │
│  │                    │  │  BootstrapHook                       │   │   │     │
│  │                    │  │  MemoryCompactionHook ───────────────┼───┘   │     │
│  │                    │  └─────────────────────────────────────┘       │     │
│  │                    │                                               │     │
│  │                    ▼                                               │     │
│  │               _acting() ◀───────────────────────────────────────────┘   │
│  │                    │                                                  │
│  │                    │  ┌─ ToolGuardMixin._acting()                   │
│  │                    │  │                                              │
│  │                    │  ├── is_denied(tool)? ──▶ Auto Deny            │
│  │                    │  │                                              │
│  │                    │  ├── is_guarded(tool)?                         │
│  │                    │  │    │                                         │
│  │                    │  │    └── consume_approval() ──▶ 预审批跳过     │
│  │                    │  │    └── guard() ──▶ findings ──▶ 审批流程    │
│  │                    │  │                                              │
│  │                    │  └── super()._acting() ──▶ 实际工具执行         │
│  │                    │                                                │
│  │                    ▼                                                │
│  │               工具执行 ──────────────────────────────────────────▶  │
│  │                    │                                                │
│  │                    ├── execute_shell_command()                       │
│  │                    ├── read_file() / write_file() / edit_file()    │
│  │                    ├── browser_use()                                │
│  │                    └── ...                                           │
│  │                                                                       │
│  └─────────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│                           工具层 (Tools)                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │   Shell     │  │   File I/O  │  │   Browser   │  │   Search    │      │
│  │             │  │             │  │             │  │             │      │
│  │ execute_    │  │ read_file   │  │ browser_    │  │ grep_search │      │
│  │ shell_cmd   │  │ write_file  │  │ use         │  │ glob_search │      │
│  │             │  │ edit_file   │  │ desktop_    │  │             │      │
│  │             │  │             │  │ screenshot  │  │             │      │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘      │
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │   Media     │  │   System    │  │   Memory    │  │   MCP       │      │
│  │             │  │             │  │             │  │             │      │
│  │ view_image  │  │ get_        │  │ create_     │  │ (MCP        │      │
│  │ send_file   │  │ current_time│  │ memory_     │  │  clients)   │      │
│  │             │  │ set_user_   │  │ search_tool │  │             │      │
│  │             │  │ timezone    │  │             │  │             │      │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│                           记忆层 (Memory)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                        MemoryManager                                        │
│                             │                                                │
│              ┌──────────────┼──────────────┐                               │
│              ▼              ▼              ▼                                │
│      ┌───────────┐  ┌───────────┐  ┌───────────┐                          │
│      │  Embedding │  │ FileStore │  │   ReMe    │                          │
│      │  (向量嵌入) │  │ (Chroma/  │  │InMemory   │                          │
│      │           │  │  Local)   │  │ Memory    │                          │
│      └───────────┘  └───────────┘  └───────────┘                          │
│              │                                               ▲              │
│              │               ┌───────────┐                    │              │
│              └──────────────▶│  compact_ │                    │              │
│                              │  memory() │                    │              │
│                              │summary_   │────────────────────┘              │
│                              │memory()   │                                     │
│                              └───────────┘                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│                           技能层 (Skills)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐               │
│   │   Builtin    │     │  Customized  │     │    Active    │               │
│   │   Skills     │     │   Skills     │     │   Skills     │               │
│   │              │     │              │     │              │               │
│   │ • browser_   │     │ ~/.copaw/    │     │ ~/.copaw/    │               │
│   │   visible    │     │ skills/      │     │ skills/      │               │
│   │ • cron       │     │ customized/  │     │ active/      │               │
│   │ • docx       │     │              │     │              │               │
│   │ • pdf        │     │              │     │              │               │
│   │ • ...        │     │              │     │              │               │
│   └──────────────┘     └──────────────┘     └──────────────┘               │
│                                                                             │
│   SKILL.md 格式:                                                            │
│   ---                                                                            │
│   name: skill_name                                                               │
│   description: 技能描述                                                         │
│   ---                                                                            │
│   # 技能指令                                                                          │
│   ...                                                                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 完整调用时序图

```
用户: "帮我搜索一下昨天的邮件"
         │
         ▼
┌─────────────────────────────────────┐
│  CoPawAgent.reply(msg)             │
│                                     │
│  1. process_file_and_media_blocks() │
│  2. is_command() → False           │
│  3. super().reply()                 │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  ReActAgent._reasoning()           │
│                                     │
│  pre_reasoning hooks:               │
│  • BootstrapHook                    │
│  • MemoryCompactionHook             │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Model.generate(response)          │
│  Reasoning: "用户想搜索邮件，我应该 │
│  使用 grep_search 工具..."          │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  ReActAgent._acting(tool_call)     │
│                                     │
│  ToolGuardMixin._acting():          │
│  • is_denied()? → No               │
│  • is_guarded()? → No              │
│  • super()._acting()               │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  execute_shell_command()            │
│  cmd: "grep -r '邮件' ~/mail/..."  │
│                                     │
│  asyncio.to_thread()                │
│  subprocess.Popen()                │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  ToolResponse → Model               │
│  Model.generate() → 格式化回复       │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  AgentScopeFormatter.format()       │
│  → 最终响应消息                      │
└─────────────────────────────────────┘
```

---

## 6. 关键设计模式

### 6.1 Mixin 组合模式

```python
class CoPawAgent(ToolGuardMixin, ReActAgent):
    # MRO: CoPawAgent → ToolGuardMixin → ReActAgent
    # ToolGuardMixin 覆盖 _acting 和 _reasoning
```

### 6.2 延迟导入

```python
# __init__.py
def __getattr__(name):
    if name == "CoPawAgent":
        from .react_agent import CoPawAgent
        return CoPawAgent
```

避免在 CLI 导入时加载重型依赖（agentscope、tools 等）。

### 6.3 钩子机制

```python
agent.register_instance_hook(
    hook_type="pre_reasoning",
    hook_name="bootstrap_hook",
    hook=bootstrap_hook.__call__,
)
```

### 6.4 命令模式

```python
# command_handler.py
SYSTEM_COMMANDS = frozenset({"compact", "new", "clear", ...})

def is_command(self, query):
    return query.startswith("/") and query in self.SYSTEM_COMMANDS
```

### 6.5 工厂模式

```python
# model_factory.py
model, formatter = create_model_and_formatter()
```

---

## 7. 配置体系

### 7.1 配置文件结构

```json
{
  "agents": {
    "language": "zh",
    "system_prompt_files": ["AGENTS.md", "SOUL.md", "PROFILE.md"],
    "running": {
      "memory_compact_threshold": 100000,
      "memory_compact_ratio": 0.5,
      "enable_tool_result_compact": true
    }
  },
  "tools": {
    "builtin_tools": {
      "execute_shell_command": { "enabled": true },
      "read_file": { "enabled": true },
      ...
    }
  }
}
```

---

## 8. 安全机制

### 8.1 工具防护级别

| 级别 | 说明 | 处理方式 |
|------|------|----------|
| denied | 完全禁止 | 自动拒绝 |
| guarded | 需要审批 | 触发 ToolGuardEngine |
| normal | 正常执行 | 直接运行 |

### 8.2 审批流程

```
Guarded Tool Call
       │
       ▼
ToolGuardEngine.guard()
       │
       ▼
有 findings?
       │
   Yes ├──▶ 返回待审批状态
   │         │
   │         ▼
   │    用户确认/拒绝
   │         │
   │    ┌────┴────┐
   │    ▼         ▼
   │  批准      拒绝
   │    │         │
   │    └──▶ super()._acting()
   │              │
   │              ▼
   │         清理 denied 消息
   │
   No ────▶ super()._acting()
```

---

## 9. 与 CLI 的交互

AgentRunner 主要通过以下方式与 CLI 交互：

```
CLI (copaw app)
     │
     │ 启动 FastAPI
     ▼
┌─────────────────┐
│  FastAPI App    │
│                 │
│  /chats/*       │◀─── chats_cmd.py (HTTP)
│  /cron/*        │◀─── cron_cmd.py (HTTP)
│  /api/agent/*   │◀─── AgentRunner
└─────────────────┘
     │
     ▼
┌─────────────────┐
│  CoPawAgent     │
│                 │
│  reply()        │
│  ├── CLI 命令   │
│  ├── 渠道消息   │
│  └── MCP 工具   │
└─────────────────┘
```
