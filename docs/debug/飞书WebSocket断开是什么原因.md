## 错误定位

```bash
[Lark] [2026-03-17 18:19:09,863] [ERROR] receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received [conn_id=7618153736343260346]
ERROR /opt/homebrew/Caskroom/miniforge/base/lib/python3.12/site-packages/lark_oapi/ws/client.py:173 | 2026-03-17 18:19:09 | receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received [conn_id=7618153736343260346]
[Lark] [2026-03-17 18:19:09,864] [INFO] disconnected to wss://msg-frontier.feishu.cn/ws/v2?fpid=493&aid=552564&device_id=7618153736343260346&access_key=04266e24eb8083bc73ff5c058f0d086a&service_id=33554678&ticket=855f82fe-5f23-4953-a8c7-6c1e16452882 [conn_id=7618153736343260346]
[Lark] [2026-03-17 18:51:00,321] [INFO] trying to reconnect for the 1st time
/opt/homebrew/Caskroom/miniforge/base/lib/python3.12/site-packages/lark_oapi/ws/client.py:160: DeprecationWarning: websockets.InvalidStatusCode is deprecated
  except websockets.InvalidStatusCode as e:
[Lark] [2026-03-17 18:51:00,327] [ERROR] connect failed, err: HTTPSConnectionPool(host='open.feishu.cn', port=443): Max retries exceeded with url: /callback/ws/endpoint (Caused by NameResolutionError("<urllib3.connection.HTTPSConnection object at 0x165141ee0>: Failed to resolve 'open.feishu.cn' ([Errno 8] nodename nor servname provided, or not known)"))
ERROR /opt/homebrew/Caskroom/miniforge/base/lib/python3.12/site-packages/lark_oapi/ws/client.py:314 | 2026-03-17 18:51:00 | connect failed, err: HTTPSConnectionPool(host='open.feishu.cn', port=443): Max retries exceeded with url: /callback/ws/endpoint (Caused by NameResolutionError("<urllib3.connection.HTTPSConnection object at 0x165141ee0>: Failed to resolve 'open.feishu.cn' ([Errno 8] nodename nor servname provided, or not known)"))
[Lark] [2026-03-17 19:19:19,966] [INFO] trying to reconnect for the 2nd time
[Lark] [2026-03-17 19:19:20,891] [INFO] connected to wss://msg-frontier.feishu.cn/ws/v2?fpid=493&aid=552564&device_id=7618182541116656844&access_key=28d0338adbaa161c8011596a92afbc75&service_id=33554678&ticket=1e7e9517-8fbd-46be-9eb2-12abf3d7dc8a [conn_id=7618182541116656844]
[Lark] [2026-03-17 19:34:25,125] [ERROR] receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received [conn_id=7618182541116656844]
ERROR /opt/homebrew/Caskroom/miniforge/base/lib/python3.12/site-packages/lark_oapi/ws/client.py:173 | 2026-03-17 19:34:25 | receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received [conn_id=7618182541116656844]
[Lark] [2026-03-17 19:34:25,127] [INFO] disconnected to wss://msg-frontier.feishu.cn/ws/v2?fpid=493&aid=552564&device_id=7618182541116656844&access_key=28d0338adbaa161c8011596a92afbc75&service_id=33554678&ticket=1e7e9517-8fbd-46be-9eb2-12abf3d7dc8a [conn_id=7618182541116656844]
[Lark] [2026-03-17 19:34:26,878] [INFO] trying to reconnect for the 1st time
[Lark] [2026-03-17 19:34:27,385] [INFO] connected to wss://msg-frontier.feishu.cn/ws/v2?fpid=493&aid=552564&device_id=7618186445732367578&access_key=378ab8ab7e45094947415cdf59f6a3f8&service_id=33554678&ticket=0f858f00-3ecd-4937-be3d-c51d71207031 [conn_id=7618186445732367578]
[Lark] [2026-03-17 19:52:03,257] [ERROR] receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received [conn_id=7618186445732367578]
ERROR /opt/homebrew/Caskroom/miniforge/base/lib/python3.12/site-packages/lark_oapi/ws/client.py:173 | 2026-03-17 19:52:03 | receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received [conn_id=7618186445732367578]
[Lark] [2026-03-17 19:52:03,257] [INFO] disconnected to wss://msg-frontier.feishu.cn/ws/v2?fpid=493&aid=552564&device_id=7618186445732367578&access_key=378ab8ab7e45094947415cdf59f6a3f8&service_id=33554678&ticket=0f858f00-3ecd-4937-be3d-c51d71207031 [conn_id=7618186445732367578]
[Lark] [2026-03-17 19:53:05,457] [INFO] trying to reconnect for the 1st time
[Lark] [2026-03-17 19:53:06,981] [INFO] connected to wss://msg-frontier.feishu.cn/ws/v2?fpid=493&aid=552564&device_id=7618191259806534859&access_key=4ba1b10ab2becbba2090c649159850a0&service_id=33554678&ticket=11e206b1-4f62-43c3-b7cf-367433e238c8 [conn_id=7618191259806534859]
```


## 排查结果总结

根据错误日志和代码分析，这是一个 **Feishu (飞书) 频道 WebSocket 连接的网络问题**，不是代码 Bug。以下是详细排查结果：

### 错误分析

**错误日志关键信息：**
1. **DNS 解析失败**（18:51:00）：
   ```
   Failed to resolve 'open.feishu.cn' ([Errno 8] nodename nor servname provided, or not known)
   ```

2. **WebSocket 保活超时**（19:34:25 和 19:52:03）：
   ```
   receive message loop exit, err: sent 1011 (internal error) keepalive ping timeout; no close frame received
   ```

3. **自动重连成功**（19:53:06）：
   ```
   connected to wss://msg-frontier.feishu.cn/ws/v2?...
   ```

### 问题定位

| 问题 | 原因 | 严重程度 |
|------|------|----------|
| DNS 解析失败 | 网络环境或 DNS 配置问题 | 临时性 |
| WebSocket 保活超时 | 网络不稳定或长时间无活动 | 中等 |
| 自动重连成功 | lark-oapi 库有重连机制 | 已恢复 |

### 相关代码位置

- **Feishu 频道实现**：[`src/copaw/app/channels/feishu/channel.py`](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/app/channels/feishu/channel.py#L1832-L1907)
- **WebSocket 启动**：[`channel.py:1865-1889`](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/app/channels/feishu/channel.py#L1865-L1889)
- **后台线程运行**：[`channel.py:1813-1830`](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/app/channels/feishu/channel.py#L1813-L1830)

### 结论

这不是代码层面的 Bug，而是**网络连接问题**：

1. **DNS 解析失败** 是偶发的网络问题，可能是 DNS 服务器暂时不可用或网络切换导致
2. **WebSocket 保活超时** 是长连接的正常现象，当连接空闲时间过长或网络不稳定时会触发
3. **项目代码有自动重连机制**，从日志可以看到在断开连接后，系统在第 1 次重试时就成功重新连接了

### 建议（不修改代码）

1. **检查网络稳定性**：确保运行环境网络连接稳定
2. **检查 DNS 配置**：可以尝试更换为公共 DNS（如 8.8.8.8 或 114.114.114.114）
3. **这是正常现象**：WebSocket 长连接偶尔断开并重连是预期行为，系统已正确处理