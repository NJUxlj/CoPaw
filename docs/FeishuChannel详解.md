# FeishuChannel 详解

## 一、架构概述

FeishuChannel 是 CoPaw 框架中连接飞书（Feishu/Lark）平台的渠道适配器，采用 **WebSocket 长连接**接收消息、**Open API** 发送消息的混合模式。

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Feishu Platform                              │
│   ┌──────────────┐                           ┌──────────────────┐   │
│   │  User/Group  │                           │  Feishu Open API │   │
│   │  Messages    │                           │  (tenant_access  │   │
│   └──────┬───────┘                           │   _token)         │   │
│          │ WebSocket                          └────────┬─────────┘   │
│          │ (Long Connection                              │            │
│          ▼                                    ┌─────────▼─────────┐  │
│   ┌─────────────────────────────────┐         │  FeishuChannel    │  │
│   │  lark-oapi WebSocket Client    │         │                   │  │
│   │  (runs in separate thread)      │         │  _ws_client       │  │
│   └─────────────┬───────────────────┘         │  _client (API)   │  │
│                 │                              │  _http (aiohttp) │  │
│                 ▼                              └────────┬────────┘  │
│   ┌─────────────────────────────────┐                   │            │
│   │  _on_message_sync               │───────────────────┘            │
│   │  (sync callback from WS thread) │        _on_message              │
│   └─────────────┬───────────────────┘        (async, main loop)       │
│                 │ asyncio.run_coroutine_threadsafe                    │
│                 ▼                                                     │
│   ┌─────────────────────────────────┐                                 │
│   │  消息处理流程                    │                                 │
│   │  1. 消息去重                     │                                 │
│   │  2. 解析 sender/chat metadata   │                                 │
│   │  3. 下载媒体资源                │                                 │
│   │  4. 构建 AgentRequest          │                                 │
│   │  5. enqueue → ChannelManager   │                                 │
│   └─────────────────────────────────┘                                 │
│                                                                     │
│   ┌─────────────────────────────────┐                                 │
│   │  回复发送流程 (send_content_parts) │                              │
│   │  1. _get_receive_for_send 解析地址  │                              │
│   │  2. 文本 → _send_text (post md)   │                              │
│   │  3. 图片 → _upload_image + send   │                              │
│   │  4. 文件 → _upload_file + send    │                              │
│   └─────────────────────────────────┘                                 │
└─────────────────────────────────────────────────────────────────────┘
```

## 二、核心设计思想

1. **线程安全的消息接收**：WebSocket 运行在独立线程（`_ws_thread`），通过 `asyncio.run_coroutine_threadsafe` 将消息转交到主 asyncio 事件循环处理
2. **Token 自动刷新**：tenant_access_token 缓存在内存，提前 FEISHU_TOKEN_REFRESH_BEFORE_SECONDS 秒刷新
3. **会话路由解耦**：接收时存储 `(receive_id, receive_id_type)`，发送时通过 session_id 反查，避免在消息体中携带完整接收ID
4. **媒体资源本地化**：图片/文件先下载到本地 `_media_dir`，再上传到 Feishu，确保可靠传输
5. **消息去重**：基于 `message_id` 的 OrderedDict 缓存，限制最大 FEISHU_PROCESSED_IDS_MAX 条

## 三、成员变量详解

### 配置类变量

| 变量 | 类型 | 说明 |
|------|------|------|
| `enabled` | `bool` | 渠道是否启用 |
| `app_id` | `str` | 飞书应用 ID |
| `app_secret` | `str` | 飞书应用密钥 |
| `bot_prefix` | `str` | 机器人发送消息的前缀（如 `[BOT] `） |
| `encrypt_key` | `str` | 事件订阅的加密密钥 |
| `verification_token` | `str` | 事件订阅的验证 Token |
| `_media_dir` | `Path` | 媒体文件本地存储目录 |

### 客户端与网络

| 变量 | 类型 | 说明 |
|------|------|------|
| `_client` | `Any` | lark-oapi HTTP 客户端，用于 API 调用（发消息、加反应等） |
| `_ws_client` | `Any` | lark-oapi WebSocket 客户端，负责长连接接收事件 |
| `_ws_thread` | `Optional[threading.Thread]` | 运行 WebSocket 的后台线程 |
| `_loop` | `Optional[asyncio.AbstractEventLoop]` | 主事件循环引用（用于 threadsafe 地投递协程） |
| `_stop_event` | `threading.Event` | 停止信号 |
| `_http` | `Optional[aiohttp.ClientSession]` | aiohttp 会话，用于直接 HTTP 请求（下载媒体、上传文件） |

### Token 管理

| 变量 | 类型 | 说明 |
|------|------|------|
| `_tenant_access_token` | `Optional[str]` | 缓存的 tenant_access_token |
| `_tenant_access_token_expire_at` | `float` | Token 过期时间戳 |
| `_token_lock` | `asyncio.Lock` | 刷新 token 时的锁 |

### 身份与缓存

| 变量 | 类型 | 说明 |
|------|------|------|
| `_bot_open_id` | `Optional[str]` | 机器人自己的 open_id（用于检测是否被@） |
| `_nickname_cache` | `Dict[str, str]` | open_id → 用户昵称 的缓存 |
| `_nickname_cache_lock` | `asyncio.Lock` | 昵称缓存访问锁 |

### 会话路由

| 变量 | 类型 | 说明 |
|------|------|------|
| `_receive_id_store` | `Dict[str, Tuple[str, str]]` | session_id → (receive_id_type, receive_id) 的内存映射 |
| `_receive_id_lock` | `asyncio.Lock` | 路由存储访问锁 |

### 消息去重

| 变量 | 类型 | 说明 |
|------|------|------|
| `_processed_message_ids` | `OrderedDict[str, None]` | 已处理 message_id 的有序集合（用于去重） |

### 继承自 BaseChannel

| 变量 | 类型 | 说明 |
|------|------|------|
| `_process` | `ProcessHandler` | 核心处理函数，调用 AI 模型 |
| `_enqueue` | `EnqueueCallback` | 消息入队回调（由 ChannelManager 设置） |
| `dm_policy` / `group_policy` | `str` | 消息过滤策略（open/allowlist） |
| `allow_from` | `set` | 允许发送消息的 sender_id 白名单 |
| `require_mention` | `bool` | 群组中是否必须 @机器人 |
| `_renderer` | `MessageRenderer` | 消息渲染器 |

## 四、工作机制详解

### 4.1 消息接收流程

```
Feishu Server (WebSocket)
    │
    ▼
[_run_ws_forever 在独立线程运行]
    │
    ▼
lark-oapi ws.Client 收到 P2ImMessageReceiveV1 事件
    │
    ▼
_on_message_sync (sync 函数，被 WS 线程调用)
    │  线程转换：通过 asyncio.run_coroutine_threadsafe
    ▼
_on_message (async 函数，在主事件循环执行)
    │
    ├─► 消息去重检查
    ├─► 忽略 bot 自身消息
    ├─► 解析 sender_id / chat_id / message_type
    ├─► 获取用户昵称（_get_user_name_by_open_id）
    ├─► 处理不同消息类型（text/post/image/file/audio）
    │       ├─► text: 提取文本，清理 @mention key
    │       ├─► post: 提取文本 + 下载内嵌图片/媒体
    │       ├─► image: 下载图片资源
    │       ├─► file/audio: 下载文件资源
    ├─► 权限检查 (_check_allowlist)
    ├─► 群组 @mention 检查 (_check_group_mention)
    ├─► 添加 Typing 反应 (_add_reaction)
    ├─► 构建 native payload dict
    └─► 调用 _enqueue(native) → ChannelManager
```

### 4.2 回复发送流程

```
Agent Response (from _process generator)
    │
    ▼
_run_process_loop (重写基类方法)
    │
    ├─► async for event in self._process(request):
    │       │
    │       ├─► event.object == "message" && status == RunStatus.Completed
    │       │       │
    │       │       ▼
    │       │       _message_to_content_parts(event)
    │       │           │
    │       │           ▼
    │       │       send_content_parts(to_handle, parts, send_meta)
    │       │           │
    │       │           ├─► _get_receive_for_send 解析 receive_id
    │       │           ├─► 文本 → _send_text (post / interactive卡片)
    │       │           ├─► 图片 → _send_image
    │       │           └─► 文件/音视频 → _send_file
    │       │
    │       └─► event.object == "response"
    │               │
    │               ▼
    │               on_event_response(request, event)
    │
    ├─► 出错 → _on_consume_error → _send_text 发送错误信息
    │
    └─► 成功 → _add_reaction(last_message_id, "DONE")
              on_reply_sent 回调
```

### 4.3 proactive send（主动发送）

用户通过外部触发（如 cron job）调用 `send(to_handle, text, meta)`:

```
send(to_handle, text, meta)
    │
    ▼
_get_receive_for_send(to_handle, meta)
    │
    ├─► 优先从 meta 中取 feishu_receive_id
    ├─► 用 _route_from_handle 解析 to_handle
    │       feishu:sw:{session_id}     → 从 _receive_id_store 查
    │       feishu:open_id:{open_id}   → 直接使用
    │       feishu:chat_id:{chat_id}   → 直接使用
    │       oc_/ou_ 前缀              → 推断 receive_id_type
    │
    ▼
_send_text(receive_id_type, receive_id, body)
```

### 4.4 Token 管理

```
_get_tenant_access_token()
    │
    ├─► 检查缓存：now < expire_at - FEISHU_TOKEN_REFRESH_BEFORE_SECONDS
    │       └─► 命中则直接返回
    │
    ├─► 加锁，再次检查（double-check）
    │
    ├─► 请求 https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal
    │
    └─► 解析返回，缓存 token 和过期时间
```

## 五、方法调用关系图

### 初始化与生命周期

```
from_env / from_config
    └── __init__

start()
    ├── _load_receive_id_store_from_disk()
    ├── 创建 _client (lark HTTP)
    ├── 创建 _ws_client (lark WS)
    │       └── _run_ws_forever (线程目标)
    │               └── ws_client.start()  [独立线程]
    ├── 创建 _http (aiohttp)
    └── _fetch_bot_open_id()

stop()
    ├── 设置 _stop_event
    ├── ws_client.stop()
    ├── ws_thread.join()
    └── _http.close()
```

### 消息处理

```
_on_message_sync (WS线程)
    └── asyncio.run_coroutine_threadsafe(_on_message, loop)

_on_message
    ├── _processed_message_ids 去重
    ├── _get_user_name_by_open_id
    │       └── _get_tenant_access_token
    ├── _download_image_resource / _download_file_resource
    │       └── _get_tenant_access_token
    ├── _check_allowlist
    ├── _check_group_mention
    ├── _add_reaction ("Typing")
    └── _enqueue(native)

send_content_parts
    ├── _get_receive_for_send
    │       ├── _route_from_handle
    │       └── _load_receive_id
    ├── _send_text
    │       ├── _build_post_content
    │       └── _send_message_sync
    ├── _send_image
    │       ├── _part_to_image_bytes
    │       │       └── _fetch_bytes_from_url
    │       ├── _upload_image_sync
    │       └── _send_message_sync
    └── _send_file
            ├── _part_to_file_path_or_url
            │       └── _fetch_bytes_from_url
            ├── _upload_file
            │       └── _get_tenant_access_token
            └── _send_message_sync

_run_process_loop (重写基类)
    ├── _process(request) [生成器，yield Event]
    ├── send_content_parts
    ├── _add_reaction("DONE")
    └── _on_reply_sent 回调
```

## 六、Session ID 与路由机制

### Session ID 生成（接收时）

```
resolve_session_id(sender_id, meta)
    │
    ├─► 群组: short_session_id(chat_id)
    ├─► P2P: 优先 short_session_id(sender_id)
    └─► fallback: channel:sender_id
```

`short_session_id_from_full_id` 取 ID 的后半段（如 `949#1d1a`）。

### to_handle 格式

| to_handle 格式 | 含义 | 路由结果 |
|---------------|------|---------|
| `feishu:sw:{session_id}` | 短 session ID | 查 `_receive_id_store` → `session_key` |
| `feishu:open_id:{open_id}` | 明确 open_id | `receive_id_type=open_id` |
| `feishu:chat_id:{chat_id}` | 明确 chat_id | `receive_id_type=chat_id` |
| `ou_...` | open_id 格式 | `receive_id_type=open_id` |
| `oc_...` | chat_id 格式 | `receive_id_type=chat_id` |

### receive_id 持久化

接收消息时，`_before_consume_process` 调用 `_save_receive_id`：
- 以 `session_id` 为 key 存储 `(receive_id_type, receive_id)`
- 以 `open_id` 为 key 也存一份（用于 cron 用 open_id 查找）
- 同时写磁盘 `feishu_receive_ids.json`

## 七、消息类型处理矩阵

| msg_type | 文本提取 | 媒体下载 | 发送方式 |
|----------|---------|---------|---------|
| `text` | `extract_json_key(content, "text")` | 无 | post md |
| `post` | `extract_post_text` | 图片/文件 key → 下载 | post md + 内嵌图片 |
| `image` | 无（显示为 [image]） | image_key → 下载 | image msg_type |
| `file` | 无（显示为 [file]） | file_key → 下载 | file msg_type |
| `audio` | 无（显示为 [audio]） | file_key → 下载为 .opus | file msg_type |
| 其他 | `[{msg_type}]` | 无 | — |

## 八、关键常量

| 常量 | 值 | 说明 |
|------|---|------|
| `FEISHU_PROCESSED_IDS_MAX` | 2000 | 消息去重 ID 缓存上限 |
| `FEISHU_NICKNAME_CACHE_MAX` | 1000 | 昵称缓存上限（LRU 淘汰） |
| `FEISHU_TOKEN_REFRESH_BEFORE_SECONDS` | 60 | token 提前刷新秒数 |
| `FEISHU_USER_NAME_FETCH_TIMEOUT` | 5.0 | 获取用户名的超时秒数 |
| `FEISHU_FILE_MAX_BYTES` | 30MB | 文件上传大小限制 |

## 九、继承关系

```
BaseChannel
    └── FeishuChannel
            ┌─────────────────────────────────────┐
            │ 重写/新增的关键方法                   │
            ├─────────────────────────────────────┤
            │ build_agent_request_from_native()   │
            │ merge_native_items()                │
            │ to_handle_from_target()             │
            │ _route_from_handle()                │
            │ get_to_handle_from_request()        │
            │ send_content_parts()                │
            │ _run_process_loop()  [重写]          │
            │ _before_consume_process()  [重写]    │
            │ send()                               │
            │ start() / stop()                     │
            │ resolve_session_id()                │
            └─────────────────────────────────────┘
```

## 十、注意事项

1. **线程安全**：`lark-oapi` 的 WebSocket client 运行在独立线程，所有需要线程安全地通过 `asyncio.run_coroutine_threadsafe` 将协程投递到主事件循环
2. **pkg_resources 兼容性**：文件头部有针对 setuptools>=82 缺失 `pkg_resources` 的兼容处理
3. **媒体路径安全**：下载和上传时对文件名做了 path traversal 防护（`Path().name` 只取 basename）
4. **去重窗口**：`_processed_message_ids` 是有序字典，超过 `FEISHU_PROCESSED_IDS_MAX` 时删除最旧的条目
5. **DONE reaction**：回复完成后会添加一个 "DONE" emoji 反应，让用户知道回复已完整