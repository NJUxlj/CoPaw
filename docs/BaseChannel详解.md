# BaseChannel 详解

## 概述

`BaseChannel` 是所有渠道（Channel）的抽象基类，定义了消息处理的统一流程。它与 `ChannelManager` 协作，通过队列接收消息、转换为 `AgentRequest`、调用 `_process` 处理、最后将响应发送回用户。

---

## 核心属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `_process` | `ProcessHandler` | 核心处理函数，接收 `AgentRequest`，返回 `Event` 流 |
| `_on_reply_sent` | `OnReplySent` | 用户回复发送成功后的回调 |
| `_enqueue` | `EnqueueCallback` | 入队回调，由 ChannelManager 设置 |
| `_renderer` | `MessageRenderer` | 消息渲染器，将 Message 转换为可发送的内容 |
| `_pending_content_by_session` | `Dict` | 无文本内容的缓存（等待文本到达后再处理） |
| `_debounce_pending` | `Dict` | 时间防抖缓冲区 |
| `_debounce_timers` | `Dict` | 防抖定时器任务 |

---

## 策略配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dm_policy` | `"open"` | 私信策略：`open` 或 `allowlist` |
| `group_policy` | `"open"` | 群聊策略：`open` 或 `allowlist` |
| `allow_from` | `set()` | 允许的用户 ID 集合 |
| `deny_message` | `""` | 拒绝访问时的消息 |
| `require_mention` | `False` | 群聊中是否需要 @ 机器人 |
| `show_tool_details` | `True` | 是否显示工具调用详情 |
| `filter_tool_messages` | `False` | 是否过滤工具消息 |
| `filter_thinking` | `False` | 是否过滤思考过程 |

---

## 工作链路详解

### 链路 1: 消息入队 (Enqueue)

```
外部消息源 → enqueue(channel_id, payload) → ChannelManager._enqueue_one()
                                              ↓
                                    检查 session 是否正在处理中
                                              ↓
                              否 → 直接放入 asyncio.Queue
                              是 → 放入 _pending 等待合并
```

**关键点：**
- `ChannelManager` 拥有队列，调用 `channel.set_enqueue(cb)` 注册回调
- `enqueue` 是线程安全的（可从同步 WebSocket 或轮询线程调用）
- 同一 session 的多条消息会合并后再处理

---

### 链路 2: 消费循环 (Consume Loop)

```
asyncio.Queue.get() → _drain_same_key() 批量取出同 session 消息
                              ↓
                    _process_batch() 合并消息
                              ↓
                    channel._consume_one_request() 或 channel.consume_one()
```

**消费者数量：** 每个 Channel 默认 4 个 worker 并行处理不同 session

---

### 链路 3: 单条消息处理 (consume_one)

```
consume_one(payload)
      ↓
┌─────────────────────────────────────────────────────────┐
│ 如果 _debounce_seconds > 0 且是 native payload:         │
│   1. 放入 _debounce_pending[key]                        │
│   2. 启动/重置定时器                                     │
│   3. 定时器到期后调用 flush() 合并并处理                  │
│                                                        │
│ 否则直接调用 _consume_one_request(payload)              │
└─────────────────────────────────────────────────────────┘
```

**防抖机制：**
- `_debounce_seconds`: 合并时间窗口（子类如 Feishu 可设置，如 0.3 秒）
- `_is_native_payload()`: 判断是否是原生 dict 格式（包含 `content_parts`）

---

### 链路 4: 请求消费核心 (_consume_one_request)

```
_consume_one_request(payload)
      ↓
1. _payload_to_request(payload)
   - 如果 payload 已有 session_id + input，直接返回
   - 否则调用 build_agent_request_from_native(payload) 转换
      ↓
2. 从 payload 提取 meta，构建 request.channel_meta
   - 从 payload["meta"] 复制一份
   - 若 payload 有 session_webhook，也注入 channel_meta
   - 挂载到 request（确保 Feishu 等子类的 _before_consume_process
     能访问到 session_webhook）
      ↓
3. _apply_no_text_debounce() 处理无文本消息
   - 如果没有文本 → 缓存到 _pending_content_by_session，返回（不处理）
   - 如果有文本 → 合并缓存内容后继续
   - 合并时：用 model_copy(update={"content": merged}) 写入
      ↓
4. get_to_handle_from_request(request) 获取路由地址
      ↓
5. _before_consume_process(request) [Hook]
   - 子类可覆盖，如 Feishu 保存 receive_id
      ↓
6. 构建 send_meta（优先从 payload 取，保留 session_webhook）
   - 从 payload["meta"] 复制
   - 若有 session_webhook 也注入
   - 若没有 payload 则从 request.channel_meta 取
   - 若 channel 有 bot_prefix 且 send_meta 中没有，注入
      ↓
7. _run_process_loop(request, to_handle, send_meta)
```

**关键实现细节：**

#### (a) channel_meta 的构建与挂载

```python
# 从 payload 构建 channel_meta，确保 session_webhook 不丢失
if isinstance(payload, dict):
    meta_from_payload = dict(payload.get("meta") or {})
    if payload.get("session_webhook"):
        meta_from_payload["session_webhook"] = payload["session_webhook"]
    # 挂载到 request，供 _before_consume_process 使用
    setattr(request, "channel_meta", meta_from_payload)
```

> 背景：`AgentRequest` schema 本身没有 `channel_meta` 字段，但 Feishu 的 `_before_consume_process` 需要通过 `request.channel_meta` 获取 `feishu_receive_id` 等路由信息。因此这里强制挂载。

#### (b) 无文本消息的合并写入

```python
should_process, merged = self._apply_no_text_debounce(session_id, contents)
if not should_process:
    return  # 无文本消息，缓存后直接返回，等后续文本

# 有文本且有缓存内容时，用 model_copy 安全写入
if hasattr(request.input[0], "model_copy"):
    request.input[0] = request.input[0].model_copy(update={"content": merged})
else:
    request.input[0].content = merged
```

> `model_copy` 是 Pydantic 模型的安全复制方式，避免直接修改原始对象。

#### (c) send_meta 的构建逻辑

```python
# 优先从 payload 构建 send_meta（保留 session_webhook）
if isinstance(payload, dict):
    send_meta = dict(payload.get("meta") or {})
    if payload.get("session_webhook"):
        send_meta["session_webhook"] = payload["session_webhook"]
else:
    send_meta = getattr(request, "channel_meta", None) or {}

# bot_prefix 注入
bot_prefix = getattr(self, "bot_prefix", None) or getattr(self, "_bot_prefix", "")
if bot_prefix and "bot_prefix" not in send_meta:
    send_meta = {**send_meta, "bot_prefix": bot_prefix}
```

> 注意：`send_meta` 和 `request.channel_meta` 都从同一个 payload 构建，但用途不同：
> - `channel_meta` 供消费流程内部使用（如保存 receive_id）
> - `send_meta` 供发送时使用（传递给 `send_content_parts`）

---

### 链路 5: 流程执行循环 (_run_process_loop)

```
_run_process_loop(request, to_handle, send_meta)
      ↓
async for event in self._process(request):
      ↓
┌──────────────────────────────────────────────────────────┐
│ event.object == "message" AND event.status == Completed: │
│   → on_event_message_completed()                        │
│   → send_message_content(to_handle, event, send_meta)    │
│                                                          │
│ event.object == "response":                              │
│   → on_event_response() [Hook]                          │
│   → 保存 last_response                                   │
└──────────────────────────────────────────────────────────┘
      ↓
处理完成后：
  1. 检查 last_response 是否有错误
  2. 调用 _on_consume_error() 发送错误消息（如果有）
  3. 调用 _on_reply_sent() 通知回复已发送
```

---

### 链路 6: 消息发送 (Send Path)

```
send_message_content(to_handle, message, meta)
      ↓
_renderer.message_to_parts(message) → List[ContentPart]
      ↓
send_content_parts(to_handle, parts, meta)
      ↓
┌─────────────────────────────────────────────────────────┐
│ 分离 text/refusal 和 media (image/video/audio/file)    │
│ 文本拼接 + media URL 添加为文本                         │
│ 调用 send(to_handle, body, meta)                        │
│ 调用 send_media() 处理每个 media part                   │
└─────────────────────────────────────────────────────────┘
```

**MessageRenderer 支持的内容类型：**
- `TextContent` - 文本
- `ImageContent` - 图片
- `VideoContent` - 视频
- `AudioContent` - 音频
- `FileContent` - 文件
- `RefusalContent` - 拒绝内容

**RenderStyle 控制：**
- `show_tool_details`: 是否显示工具调用详情
- `supports_markdown`: 是否支持 Markdown
- `use_emoji`: 是否使用 Emoji
- `filter_thinking`: 是否过滤思考过程

---

### 链路 7: 错误处理 (_on_consume_error)

```
异常捕获 或 last_response.error 存在
      ↓
_on_consume_error(request, to_handle, err_text)
      ↓
send_content_parts(to_handle, [TextContent(text=err_text)], channel_meta)
```

---

## 消息合并策略

### 1. Native Items 合并 (merge_native_items)

用于同一 session 的多个 native payload 合并：

```python
{
    "channel_id": first.channel_id,
    "sender_id": first.sender_id,
    "content_parts": 所有 payload 的 content_parts 拼接,
    "meta": {
        "reply_future": ...,
        "reply_loop": ...,
        "incoming_message": ...,
        "conversation_id": ...
    }
}
```

### 2. AgentRequest 合并 (merge_requests)

用于同一 session 的多个 `AgentRequest` 合并：
- 拼接所有 request 的 `input[0].content`
- 保留第一个 request 的 meta/session

### 3. 无文本防抖 (_apply_no_text_debounce)

如果消息没有文本（如只有图片），会缓存等待：
- 等待后续文本消息
- 文本到达后，将缓存的 content 与新 content 合并处理

---

## 子类需要实现的方法

| 方法 | 说明 |
|------|------|
| `from_env(process, on_reply_sent)` | 从环境变量创建 Channel |
| `from_config(process, config, ...)` | 从配置创建 Channel |
| `start()` | 启动 Channel（如监听 WebSocket） |
| `stop()` | 停止 Channel |
| `send(to_handle, text, meta)` | 发送文本消息 |
| `build_agent_request_from_native(payload)` | 将原生消息转换为 AgentRequest |

---

## 可覆盖的 Hook 方法

| 方法 | 说明 |
|------|------|
| `_before_consume_process(request)` | 处理前 Hook |
| `on_event_message_completed(...)` | 消息完成事件处理 |
| `on_event_response(...)` | 响应事件处理 |
| `_on_debounce_buffer_append(...)` | 防抖缓冲区追加 Hook |
| `send_media(...)` | 发送媒体附件（默认追加 URL 到文本） |

---

## 时序图

```
用户消息
    │
    ▼
ChannelManager.enqueue()
    │
    ▼
asyncio.Queue
    │
    ▼
_consume_channel_loop()
    │
    ├─► _drain_same_key() ──► 批量同 session 消息
    │                            │
    │                            ▼
    │                      _process_batch()
    │                            │
    │                            ▼
    └──────────────────► consume_one()
                              │
                              ▼
                    ┌─────────────────┐
                    │  防抖处理?       │
                    │  (_debounce_sec) │
                    └────────┬────────┘
                             │
                             ▼
                    _consume_one_request()
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
    build_agent_request  无文本防抖   _before_consume_process
              │              │              │
              └──────────────┬┴──────────────┘
                             │
                             ▼
                    _run_process_loop()
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        on_event_       on_event_       错误处理
       message_completed response
              │              │
              ▼              ▼
        send_message_content()
              │
              ▼
        _renderer.message_to_parts()
              │
              ▼
        send_content_parts()
              │
              ▼
        send(to_handle, text, meta)
              │
              ▼
        send_media() (如果有媒体)
              │
              ▼
        _on_reply_sent() (通知完成)
```

---

## 配置示例

```python
channel = SomeChannel(
    process=stream_query,           # AgentRequest -> AsyncIterator[Event]
    on_reply_sent=on_reply_sent,     # 回复发送后的回调
    show_tool_details=True,           # 显示工具调用
    filter_tool_messages=False,      # 不过滤工具消息
    filter_thinking=False,           # 不过滤思考过程
    dm_policy="open",               # 私信策略
    group_policy="open",            # 群聊策略
    allow_from=["user1", "user2"],  # 允许的用户
    deny_message="Unauthorized",    # 拒绝消息
    require_mention=False,          # 群聊是否需要 @ 机器人
)
```

---

## 关键设计模式

1. **队列所有权的分离**：队列和消费者循环在 `ChannelManager` 中，Channel 只定义如何消费
2. **Payload 类型抽象**：支持原生 dict payload 和 `AgentRequest` 两种格式
3. **多层防抖**：
   - 时间防抖（`_debounce_seconds`）：合并短时间内同一 session 的消息
   - 内容防抖（`_apply_no_text_debounce`）：等待文本到达后再处理无文本消息
4. **Session 并行处理**：多个 worker 可以并行处理不同 session
5. **Hook 机制**：多处留有 Hook 方法供子类定制
