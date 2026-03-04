# CoPaw Memory 模块结构与调用链

本文档详细剖析 CoPaw 项目中 memory 模块的架构设计、核心类功能以及完整的调用链。

---

## 一、模块结构

```
src/copaw/agents/memory/
├── __init__.py              # 导出三个核心类
├── copaw_memory.py          # CoPawInMemoryMemory - 扩展的内存存储
├── memory_manager.py        # MemoryManager - 高级内存管理
└── agent_md_manager.py      # AgentMdManager - Markdown 文件管理
```

---

## 二、核心类详解

### 1. CoPawInMemoryMemory

**继承**: `agentscope.memory.InMemoryMemory`

**核心功能**:
- 扩展基础内存类，添加 **compressed summary** 支持
- `get_memory()` - 获取消息，支持按 mark 过滤、排除已压缩消息
- `get_compressed_summary()` - 获取压缩摘要
- `state_dict() / load_state_dict()` - 序列化/反序列化

**关键特性**:
```python
# 获取内存时自动添加压缩摘要到上下文
messages = await memory.get_memory(
    exclude_mark=_MemoryMark.COMPRESSED,  # 排除已压缩的消息
    prepend_summary=True,                  # 在开头添加摘要
)
```

**使用场景**:
- 每个 Agent 实例拥有独立的内存对象
- 存储当前会话的对话历史
- 支持消息标记（如 COMPRESSED）来管理上下文窗口

---

### 2. MemoryManager

**继承**: `ReMeFb` (来自 `reme` 包，可选依赖)

**核心功能**:

| 功能 | 方法 | 说明 |
|------|------|------|
| 内存压缩 | `compact_memory()` | 将历史消息压缩成摘要 |
| 内存总结 | `summary_memory()` | 生成每日/会话总结 |
| 语义搜索 | `memory_search()` | 向量搜索 MEMORY.md |
| 文件读取 | `memory_get()` | 读取记忆文件内容 |

**初始化配置**:
```python
MemoryManager(
    working_dir=str(WORKING_DIR),
    # 向量搜索配置 (可选)
    embedding_api_key=...,
    embedding_base_url=...,
    # 存储后端: local (Windows) 或 chroma (其他)
    default_file_store_config={
        "backend": "chroma",      # 或 "local"
        "vector_enabled": True,   # 启用向量搜索
        "fts_enabled": True,      # 启用全文搜索
    }
)
```

**内部组件**:
- `TimestampedDashScopeChatFormatter` - 带时间戳的消息格式化器
- `Toolkit` - 工具集（read_file, write_file, edit_file）
- 异步任务管理 - `summary_tasks` 用于后台总结任务

---

### 3. AgentMdManager

**简单工具类**，管理 `working_dir` 和 `memory_dir` 中的 Markdown 文件:

| 方法 | 功能 |
|------|------|
| `list_working_mds()` | 列出工作目录中的 Markdown 文件 |
| `read_working_md()` | 读取工作目录中的 Markdown 文件 |
| `write_working_md()` | 写入工作目录中的 Markdown 文件 |
| `list_memory_mds()` | 列出 memory 目录中的文件 |
| `read_memory_md()` | 读取 memory 目录中的文件 |
| `write_memory_md()` | 写入 memory 目录中的文件 |

**单例实例**:
```python
AGENT_MD_MANAGER = AgentMdManager(working_dir=WORKING_DIR)
```

---

## 三、调用链架构

### 整体架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      AgentRunner (app/runner/runner.py)        │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  MemoryManager (单例，init_handler 创建)                  │ │
│  │  - 启动时: memory_manager.start()                        │ │
│  │  - 关闭时: memory_manager.close()                        │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────┬──────────────────────────────────┘
                           │ 传递给
┌──────────────────────────▼──────────────────────────────────┐
│                    CoPawAgent (react_agent.py)                 │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  self.memory = CoPawInMemoryMemory()                    │ │
│  │  self.memory_manager = MemoryManager (外部传入)          │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────┬──────────────────────────────────┘
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
┌─────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ CommandHandler│  │ MemoryCompaction │  │ memory_search   │
│ (命令处理)   │  │ Hook (自动压缩)  │  │ Tool (搜索工具)  │
└─────────────┘  └─────────────────┘  └─────────────────┘
```

---

## 四、详细调用链

### 1. 初始化链

```
app/runner/runner.py:AgentRunner.init_handler()
    ├── 创建 MemoryManager(working_dir)
    │   ├── 读取 Embedding 配置 (环境变量)
    │   ├── 配置存储后端 (local/chroma)
    │   └── 初始化向量搜索
    └── memory_manager.start()  # 启动后台服务
```

创建 CoPawAgent 时:
```
react_agent.py:CoPawAgent.__init__()
    ├── self.memory = CoPawInMemoryMemory()  # 每个 Agent 有自己的内存
    ├── self._setup_memory_manager()
    │   ├── memory_manager.chat_model = self.model
    │   ├── memory_manager.formatter = self.formatter
    │   └── 注册 memory_search 工具到 toolkit
    └── _register_hooks()
        └── 注册 MemoryCompactionHook (如启用)
```

---

### 2. 消息处理链

```
用户发送消息
    │
    ▼
query_handler() 创建 Agent
    │
    ▼
session.load_session_state()  # 恢复历史内存
    │
    ▼
agent.reply(msg) 处理消息
    │
    ├── hooks 执行 (pre_reasoning)
    │   └── MemoryCompactionHook.__call__()
    │       ├── 获取内存: agent.memory.get_memory(exclude_mark=COMPRESSED)
    │       ├── 计算 Token 数
    │       └── 如超过阈值:
    │           ├── memory_manager.compact_memory()  # 压缩旧消息
    │           └── agent.memory.update_compressed_summary()  # 保存摘要
    │           └── agent.memory.update_messages_mark(COMPRESSED)  # 标记
    │
    └── 正常回复流程
        └── 保存状态: session.save_session_state()
```

---

### 3. 系统命令链

```
用户输入系统命令 (/compact, /new, /clear, /history, /compact_str, /await_summary)
    │
    ▼
CommandHandler.handle_command()
    ├── /compact
    │   └── memory_manager.compact_memory(messages_to_summarize=...)
    │       └── ReActAgent 生成摘要
    │
    ├── /new
    │   └── memory_manager.add_async_summary_task(messages=...)
    │       └── 后台异步生成总结
    │
    ├── /clear
    │   ├── memory.content.clear()
    │   └── memory.update_compressed_summary("")
    │
    ├── /history
    │   └── 统计 Token 使用量、上下文占用比例
    │
    ├── /compact_str
    │   └── memory.get_compressed_summary()
    │
    └── /await_summary
        └── memory_manager.await_summary_tasks()
```

---

### 4. 记忆搜索链

```
Agent 需要搜索历史记忆
    │
    ▼
调用 memory_search 工具 (agents/tools/memory_search.py)
    │
    ▼
MemoryManager.memory_search(query, max_results, min_score)
    ├── 更新 Embedding 环境变量
    ├── 执行语义搜索 (ReMeFb.memory_search)
    └── 返回 ToolResponse (文本块)
```

---

## 五、内存压缩机制详解

### 压缩流程

```
原始消息: [Msg1, Msg2, Msg3, Msg4, Msg5...Msg100]
              │
              ▼ Token 数超过阈值 (默认 70% 的 max_input_length)
         触发压缩
              │
              ▼
    ┌─────────────────┐
    │ 保留系统提示词  │ ← 始终保留
    ├─────────────────┤
    │ 压缩区域        │ ← Msg1-94 被压缩
    │ 生成摘要:       │
    │ "用户询问了XX   │
    │  问题，助手..." │
    ├─────────────────┤
    │ 保留最近消息    │ ← Msg95-100 (默认保留 3 条)
    └─────────────────┘
              │
              ▼
最终内存: [System] + [Summary] + [Msg95, Msg96, Msg97, Msg98, Msg99, Msg100]
```

### 消息标记系统

```python
class _MemoryMark:
    COMPRESSED = "compressed"  # 已压缩的消息标记
```

- 被标记的消息在 `get_memory()` 时默认被排除
- 压缩摘要通过 `prepend_summary=True` 添加到上下文开头

---

## 六、环境变量配置

```bash
# ========== Memory 压缩配置 ==========
COPAW_MEMORY_COMPACT_KEEP_RECENT=3    # 保留最近 N 条消息 (默认 3)
COPAW_MEMORY_COMPACT_RATIO=0.7        # 压缩阈值比例 (默认 0.7)
MAX_INPUT_LENGTH=131072               # 最大输入长度 (默认 128K)

# ========== 向量搜索配置 (可选) ==========
EMBEDDING_API_KEY=your_api_key
EMBEDDING_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
EMBEDDING_MODEL_NAME=text-embedding-v4
EMBEDDING_DIMENSIONS=1024
EMBEDDING_CACHE_ENABLED=true

# ========== 存储后端配置 ==========
MEMORY_STORE_BACKEND=auto  # 可选: auto/local/chroma
                          # auto: Windows 用 local，其他用 chroma
FTS_ENABLED=true           # 启用全文搜索

# ========== 工具结果截断配置 ==========
ENABLE_TRUNCATE_TOOL_RESULT_TEXTS=false  # 是否截断工具结果文本
DEFAULT_COMPACT_TOOL_RESULT_MAX_LENGTH=10000
```

---

## 七、文件存储位置

```
~/.copaw/                          # 工作目录 (可配置)
├── memory/                        # AgentMdManager 管理的记忆文件
│   ├── MEMORY.md                 # 主记忆文件
│   ├── memory-2024-01-15.md      # 按日期分割的记忆
│   └── *.md                      # 其他记忆片段
│
├── sessions/                     # 会话状态 (SafeJSONSession)
│   └── {session_id}.json         # 包含 CoPawInMemoryMemory 的序列化数据
│       ├── content: 消息列表
│       └── _compressed_summary: 压缩摘要
│
└── dingtalk_session_webhooks.json # 钉钉 sessionWebhook 缓存
```

---

## 八、关键设计特点

### 1. 双层内存架构

| 层级 | 类 | 作用 | 生命周期 | 持久化 |
|------|-----|------|----------|--------|
| 会话内存 | `CoPawInMemoryMemory` | 存储当前对话历史 | 每个 Agent 实例 | session.json |
| 长期记忆 | `MemoryManager` | 文件存储、向量搜索、摘要 | 全局单例 | MEMORY.md + 向量库 |

### 2. 自动内存管理

- **自动压缩**: 当 Token 数超过阈值时自动触发
- **后台总结**: `/new` 命令触发异步总结任务
- **上下文优化**: 优先保留最近消息，旧消息压缩成摘要

### 3. 可扩展的搜索能力

- **向量搜索**: 基于 Embedding 的语义搜索 (需配置 API Key)
- **全文搜索**: 基于关键词的搜索
- **文件读取**: 精确定位记忆文件的特定行

---

## 九、使用示例

### 初始化 MemoryManager

```python
from copaw.agents.memory import MemoryManager
from copaw.constant import WORKING_DIR

memory_manager = MemoryManager(working_dir=str(WORKING_DIR))
await memory_manager.start()

# 使用完毕后
await memory_manager.close()
```

### 创建带内存的 Agent

```python
from copaw.agents.react_agent import CoPawAgent

agent = CoPawAgent(
    env_context="可选的环境上下文",
    memory_manager=memory_manager,  # 传入 MemoryManager
    enable_memory_manager=True,     # 启用内存管理
)
```

### 使用记忆搜索工具

```python
# Agent 会自动注册 memory_search 工具
# 在对话中可以直接调用:
# > 请搜索我昨天关于项目的讨论
# Agent 会调用 memory_search(query="项目讨论")
```

### 系统命令

```
/compact        # 手动压缩历史消息
/new            # 开启新对话，保留摘要
/clear          # 清空当前内存
/history        # 查看内存使用统计
/compact_str    # 查看当前压缩摘要
/await_summary  # 等待后台总结任务完成
```

---

## 十、注意事项

1. **MemoryManager 是可选依赖**: 需要安装 `reme` 包，否则向量搜索功能不可用
2. **Session Webhook 有过期时间**: 钉钉等渠道的主动推送需要用户先与 Bot 交互
3. **向量搜索需要 API Key**: 配置 `EMBEDDING_API_KEY` 才能启用语义搜索
4. **内存压缩不可逆**: 被标记为 COMPRESSED 的消息将不再参与推理（但保留在 session 中）
