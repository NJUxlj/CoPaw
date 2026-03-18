# MCP（Model Context Protocol）的三种传输类型
    
---

## MCP Transport 三种类型概述

`streamable_http`、`stdio` 和 `sse` 是 MCP 协议的**传输层**实现方式，用于 AI 客户端与 MCP 服务器之间的通信。

| 传输类型 | 适用场景 | 通信方式 |
|----------|----------|----------|
| `stdio` | 本地运行的 MCP 服务器 | 标准输入/输出 |
| `streamable_http` | 远程 MCP 服务器 | HTTP + 流式响应 |
| `sse` | 远程 MCP 服务器 | HTTP + Server-Sent Events |

---

## 1. stdio - 标准输入/输出传输

```python
transport: Literal["stdio", "streamable_http", "sse"] = "stdio"
command: str = ""
args: List[str] = Field(default_factory=list)
env: Dict[str, str] = Field(default_factory=dict)
cwd: str = ""
```

### 工作机制

```
┌─────────────────┐      stdin/stdout      ┌─────────────────┐
│   AI 客户端     │ ◄────────────────────► │  MCP 服务器     │
│  (CoPaw)        │     子进程通信          │  (本地进程)     │
└─────────────────┘                        └─────────────────┘
```

### 特点

- **本地通信**：MCP 服务器作为子进程启动
- **双向流**：通过 `stdin` 发送请求，通过 `stdout` 接收响应
- **配置项**：
  - `command`: 启动命令（如 `python`, `node`, `/usr/local/bin/mcp-server`）
  - `args`: 命令行参数
  - `env`: 环境变量
  - `cwd`: 工作目录

### 示例配置

```json
{
  "name": "filesystem",
  "transport": "stdio",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
}
```

---

## 2. streamable_http - HTTP 流式传输（推荐）

```python
url: str = ""
headers: Dict[str, str] = Field(default_factory=dict)
```

### 工作机制

```
┌─────────────────┐                              ┌─────────────────┐
│   AI 客户端     │ ──── HTTP POST (JSON) ──────► │  MCP 服务器     │
│  (CoPaw)        │ ◄─── 流式响应 (ndjson) ────── │  (远程服务)     │
└─────────────────┘                              └─────────────────┘
```

### 特点

- **远程通信**：通过 HTTP 请求连接到远程 MCP 服务器
- **流式响应**：使用 `ndjson`（newline-delimited JSON）格式逐行返回
- **无状态**：每个请求独立，不维持持久连接
- **最新标准**：MCP 1.0 推荐的传输方式
- **自动选择**：如果没有 `command` 但有 `url`，自动使用此模式

### 示例配置

```json
{
  "name": "github",
  "transport": "streamable_http",
  "url": "https://api.example.com/mcp",
  "headers": {
    "Authorization": "Bearer token123"
  }
}
```

### 请求/响应格式

```json
// 请求
{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}

// 响应（多行 JSON）
{"jsonrpc": "2.0", "id": 1, "result": {"tools": [...]}}
{"jsonrpc": "2.0", "id": 2, "result": {"content": [...]}}
```

---

## 3. sse - Server-Sent Events 传输

```python
# 与 streamable_http 共用相同的配置
url: str = ""
headers: Dict[str, str] = Field(default_factory=dict)
```

### 工作机制

```
┌─────────────────┐                              ┌─────────────────┐
│   AI 客户端     │ ──── HTTP POST ─────────────► │  MCP 服务器     │
│  (CoPaw)        │ ◄─── SSE (事件流) ────────── │  (远程服务)     │
└─────────────────┘                              └─────────────────┘
```

### 特点

- **远程通信**：通过 HTTP 连接到远程 MCP 服务器
- **单向事件流**：服务器主动推送事件到客户端
- **有状态**：需要维持连接
- **旧版标准**：早期 MCP 使用的传输方式
- **兼容性**：一些旧版 MCP 服务器仍使用此方式

### 示例配置

```json
{
  "name": "brave-search",
  "transport": "sse",
  "url": "https://search.example.com/sse"
}
```

### 请求/响应格式

```
// 响应（SSE 格式）
event: message
data: {"jsonrpc": "2.0", "id": 1, "result": {...}}

event: message
data: {"jsonrpc": "2.0", "id": 2, "result": {...}}
```

---

## 对比总结

| 特性 | stdio | streamable_http | sse |
|------|-------|-----------------|-----|
| **通信方式** | 进程间 | HTTP | HTTP |
| **适用场景** | 本地 | 远程 | 远程 |
| **连接类型** | 长连接 | 无状态 | 长连接 |
| **流式支持** | 原生 | ndjson | SSE |
| **复杂度** | 低 | 中 | 中 |
| **推荐程度** | 本地首选 | ✅ 推荐 | 兼容旧版 |

---

## 代码中的自动检测逻辑

从你提供的代码中可以看到自动检测逻辑：

```python
# 如果有 url/baseUrl 但没有 command，自动使用 streamable_http
if (
    "transport" not in payload
    and (payload.get("url") or payload.get("baseUrl"))
    and not payload.get("command")
):
    payload["transport"] = "streamable_http"

# 规范化传输名称
transport_alias_map = {
    "streamablehttp": "streamable_http",
    "http": "streamable_http",
    "stdio": "stdio",
    "sse": "sse",
}
```

这个设计非常智能，用户只需要提供 `url` 或 `command`，系统会自动选择合适的传输类型！