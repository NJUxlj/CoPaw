# Reception 接入 CoPaw 方案

> 版本：v1.0 | 日期：2026-03-20 | 作者：AI Architect

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [两个项目的架构差异分析](#2-两个项目的架构差异分析)
3. [接入形式决策](#3-接入形式决策)
4. [整体架构设计](#4-整体架构设计)
5. [详细实现方案](#5-详细实现方案)
6. [配置设计](#6-配置设计)
7. [数据流设计](#7-数据流设计)
8. [前端适配方案](#8-前端适配方案)
9. [依赖与环境](#9-依赖与环境)
10. [实施步骤与优先级](#10-实施步骤与优先级)
11. [风险与缓解](#11-风险与缓解)
12. [测试策略](#12-测试策略)

---

## 1. 背景与目标

### 1.1 背景

**service_reception** 是一套基于 LangGraph 的医疗信息化智能前台系统，核心提供两个子智能体能力：

| 子智能体 | 代码标识 | 功能 | 外部端点 |
|----------|----------|------|----------|
| **ChatBI** (数据分析) | `data_analysis` | 查询中台指标/维度，返回数据卡片 | `{domain}/hdos-chat-ai/chatAi/getMessage` |
| **KnowledgeQA** (知识问答) | `knowledge_qa` | 检索企业知识库，返回文档答案 | `{domain}/ai-knowledege/knowledge_qa/streaming` |

两个功能共享同一工作流模式：**记忆检索 → 意图识别 → 任务规划(plan) → 执行调度(execute) → 结果整合(answer) → 记忆保存(end)**。

### 1.2 目标

将 ChatBI 和 KnowledgeQA 的**调用能力**接入 CoPaw，使 CoPaw 的 agent 能够：
- 通过自然语言触发数据分析查询（ChatBI）
- 通过自然语言触发知识库检索（KnowledgeQA）
- 在任何已接入的频道（钉钉、飞书、QQ、Discord、Console 等）中使用这两个能力

### 1.3 不做的事

- **不迁移 reception 的 LangGraph 工作流**到 CoPaw（CoPaw 自有 ReAct 推理循环）
- **不迁移 reception 的记忆系统**（CoPaw 有自己的双层记忆；reception 的 MemOS/Redis 由 reception 服务端自行管理）
- **不迁移 reception 的意图识别/任务规划模块**（CoPaw 的 ReAct agent 自身具备意图理解和工具调用规划能力）

**核心思路：CoPaw 作为调用方，reception 的 ChatBI 和 KnowledgeQA 作为被调用的外部服务端点。**

---

## 2. 两个项目的架构差异分析

| 维度 | service_reception | CoPaw |
|------|-------------------|-------|
| **Agent 框架** | LangGraph StateGraph (显式节点编排) | AgentScope ReActAgent (LLM 自主推理-行动循环) |
| **工具调用** | 通过 plan → executor 显式分派到子智能体 | LLM 自主选择 tool function 调用 |
| **意图识别** | 独立 LLM 节点 (intention_node) | ReAct 内嵌（LLM 自行判断使用哪个工具） |
| **任务规划** | 独立 LLM 节点 (planner_node)，输出 TodoList | ReAct 循环隐式规划（思考→行动→观察） |
| **记忆** | 5 维记忆 (MemOS + Redis + Milvus) | 双层记忆 (InMemoryMemory + ReMe-AI) |
| **配置管理** | Nacos 热更新 | config.json + ConfigWatcher 热更新 |
| **外部服务调用** | HTTP SSE 流式调用子智能体端点 | 工具函数内部封装 |

**关键洞察**：reception 的整个 6 节点工作流（memory → intention → plan → execute → answer → memory_save）中，CoPaw 真正需要的只是 **execute 阶段对 ChatBI/KnowledgeQA 端点的 HTTP 调用**。CoPaw 的 ReAct agent 天然完成了 reception 中 intention + plan 的职责——LLM 看到工具描述后自主决定调哪个工具、传什么参数。

---

## 3. 接入形式决策

### 3.1 候选方案对比

| 方案 | 描述 | 优点 | 缺点 | 适合度 |
|------|------|------|------|--------|
| **A. Tool (工具函数)** | 在 `agents/tools/` 下新增 `chatbi.py` 和 `knowledgeqa.py`，注册为 agent 可调用的工具 | 最自然，agent 根据用户意图自主选择调用；响应格式可控；支持配置化启用/禁用 | 需要写 Python 代码 | ★★★★★ |
| **B. Skill (SKILL.md)** | 编写 Markdown 文件指导 agent 如何使用 shell/HTTP 调用服务 | 无需写代码，纯 Markdown | ChatBI/KnowledgeQA 的 SSE 流解析复杂，shell curl 无法处理；结果格式化困难 | ★★ |
| **C. MCP Server** | 将 ChatBI/KnowledgeQA 包装为 MCP 工具服务器 | 标准协议，热更新，独立进程 | 需额外维护 MCP server 进程；过度工程化 | ★★★ |
| **D. Hook** | 在 pre_reasoning 阶段拦截特定意图 | 可以做前置检测 | Hook 不适合承载完整的外部服务调用和结果格式化 | ★ |
| **E. 混合：Tool + Skill** | Tool 提供实际调用能力，Skill 提供使用指导 | 最佳用户体验：agent 既有工具又有使用指南 | 需要同时维护两种文件 | ★★★★★ |

### 3.2 最终决策：Tool + Skill 混合方案（方案 E）

**理由**：

1. **Tool** 是核心：ChatBI 和 KnowledgeQA 的 HTTP SSE 流式响应需要 Python 代码解析（JSON chunk 拼装、数据卡片提取、文档 URL 映射等），纯 Markdown Skill 无法完成。

2. **Skill** 作为辅助：提供使用指南，告诉 agent 何时使用、如何组合参数、如何理解返回结果。这对 LLM 理解工具用途极为重要（尤其是 ChatBI 的复杂场景——指标查询 vs 维度下钻 vs 极值取数 vs 数据对比）。

3. 不选 MCP：这两个功能本质上是对特定 API 的封装调用，MCP 增加了不必要的进程管理复杂度。如果未来 reception 演进为通用平台，可以再考虑 MCP 化。

---

## 4. 整体架构设计

```
┌──────────────────────────────────────────────────────────┐
│                      CoPaw Agent                         │
│                    (ReActAgent)                           │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │              System Prompt                        │    │
│  │  AGENTS.md + SOUL.md + PROFILE.md                │    │
│  │  + [Skill: reception_chatbi]                     │    │
│  │  + [Skill: reception_knowledgeqa]                │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │              Toolkit (工具注册表)                  │    │
│  │                                                    │    │
│  │  Built-in Tools:                                   │    │
│  │    shell, read_file, write_file, edit_file,       │    │
│  │    browser_use, desktop_screenshot, ...            │    │
│  │                                                    │    │
│  │  Reception Tools (新增):                           │    │
│  │    ├── query_chatbi        <- ChatBI 数据查询      │    │
│  │    └── query_knowledge_base <- 知识库问答          │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  ReAct Loop:                                             │
│    思考 -> 选择工具(query_chatbi / query_knowledge_base) │
│    -> 执行工具 -> 观察结果 -> 思考 -> 回复用户           │
└──────────────────────────────────────────────────────────┘
           │                          │
           ▼                          ▼
┌──────────────────┐    ┌──────────────────────┐
│  ChatBI Server   │    │  KnowledgeQA Server  │
│  (HTTP SSE)      │    │  (HTTP SSE)          │
│                  │    │                      │
│  /hdos-chat-ai/  │    │  /ai-knowledege/     │
│  chatAi/         │    │  knowledge_qa/       │
│  getMessage      │    │  streaming           │
└──────────────────┘    └──────────────────────┘
```

---

## 5. 详细实现方案

### 5.1 新增文件清单

```
src/copaw/
├── agents/
│   ├── tools/
│   │   ├── chatbi.py                     # ChatBI 工具函数
│   │   ├── knowledgeqa.py                # KnowledgeQA 工具函数
│   │   └── _reception_client.py          # 共享的 HTTP SSE 客户端
│   └── skills/
│       ├── reception_chatbi/
│       │   └── SKILL.md                  # ChatBI 使用指南
│       └── reception_knowledgeqa/
│           └── SKILL.md                  # KnowledgeQA 使用指南
├── config/
│   └── config.py                         # 新增 ReceptionConfig (修改已有文件)
```

### 5.2 共享 HTTP SSE 客户端：`_reception_client.py`

ChatBI 和 KnowledgeQA 都使用 HTTP POST + SSE 流式响应。提取共享客户端：

```python
# -*- coding: utf-8 -*-
"""Shared HTTP SSE streaming client for reception services."""

import logging
from typing import AsyncGenerator

import httpx

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT = 120


async def post_sse_stream(
    url: str,
    payload: dict,
    timeout: int = DEFAULT_TIMEOUT,
) -> AsyncGenerator[dict, None]:
    """Send POST request and yield parsed JSON chunks from SSE stream.

    Args:
        url: Full URL of the SSE endpoint.
        payload: JSON body to POST.
        timeout: Request timeout in seconds.

    Yields:
        Parsed JSON dict for each SSE chunk.
    """
    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream(
            "POST",
            url,
            json=payload,
        ) as response:
            response.raise_for_status()
            buffer = ""
            async for chunk in response.aiter_text():
                buffer += chunk
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith("data:"):
                        line = line[5:].strip()
                    if line == "[DONE]":
                        return
                    try:
                        import ujson
                        yield ujson.loads(line)
                    except Exception:
                        continue
```

> **注**：reception 原有的 `get_post_stream` 是同步 `requests` 库。CoPaw 的工具是 async 的，这里改为 `httpx` 异步流式调用。需要 `pip install httpx ujson`。

### 5.3 ChatBI 工具：`chatbi.py`

```python
# -*- coding: utf-8 -*-
"""ChatBI data analysis tool for querying business metrics."""

import logging
from typing import Optional

from agentscope.message import TextBlock
from agentscope.tool import ToolResponse

from ...config import load_config

logger = logging.getLogger(__name__)


async def query_chatbi(
    query: str,
    session_id: Optional[str] = None,
) -> ToolResponse:
    """Query business metrics and KPIs via the ChatBI data analysis service.

    Use this tool when the user asks about business data, metrics, KPIs,
    statistics, trends, or comparisons. Supports:
    - Single/multi-metric queries (e.g., "本月门诊接诊人数和收入")
    - Dimension drill-down by time, department, doctor, etc.
    - Top N / extreme value queries (e.g., "收入排名前十的科室")
    - Data comparison (month-over-month, year-over-year)

    Args:
        query (`str`):
            Natural language question about business data or metrics.
            Keep each query to 3 or fewer metrics for best results.
        session_id (`Optional[str]`):
            Optional session ID for conversation continuity.
            If not provided, a random one will be generated.

    Returns:
        `ToolResponse`:
            Structured data analysis results including metric values,
            data cards, and analysis process details.
    """
    from ._reception_client import post_sse_stream

    config = load_config()
    reception = getattr(config, "reception", None)
    if reception is None or not reception.chatbi.enabled:
        return ToolResponse(
            content=[TextBlock(
                type="text",
                text="Error: ChatBI is not configured. "
                     "Please set reception.chatbi in config.json.",
            )],
        )

    chatbi_cfg = reception.chatbi
    url = chatbi_cfg.domain.rstrip("/") + chatbi_cfg.endpoint

    import uuid
    payload = {
        "wsUrl": chatbi_cfg.ws_url,
        "message": query,
        "loginInfo": chatbi_cfg.login_info or {},
        "sessionId": session_id or str(uuid.uuid4()),
    }

    try:
        card_list = []
        thinking_steps = []

        async for chunk in post_sse_stream(url, payload):
            if chunk is None:
                continue

            # 最终卡片结果（含 cardType 字段）
            if "cardType" in chunk:
                card_title = chunk.get("cardTitle", "")
                if "pcTemplateForMoreIndicators" in chunk:
                    metrics = chunk["pcTemplateForMoreIndicators"]
                    for m in metrics:
                        title = m.get("title", "")
                        value = m.get("value", m.get("formatValue", "-"))
                        time_val = m.get("timeValue", "")
                        card_list.append(
                            f"- {title}: {value} ({time_val})"
                        )
                elif "metricDataList" in chunk:
                    metric_name = chunk.get("metricName", "")
                    for item in chunk["metricDataList"]:
                        time_val = item.get("timeValue", "")
                        value = item.get("value", "-")
                        dim = item.get("dimensionName", "")
                        suffix = f" [{dim}]" if dim else ""
                        card_list.append(
                            f"- {metric_name}: {value} "
                            f"({time_val}){suffix}"
                        )
                else:
                    card_list.append(
                        f"- {card_title or '(数据卡片)'}"
                    )
            else:
                step = chunk.get("step", "")
                content = chunk.get("content", "")
                if content:
                    thinking_steps.append(f"[Step {step}] {content}")

        # 组装结果
        if card_list:
            result_text = "## 数据查询结果\n\n"
            result_text += "\n".join(card_list)
            if thinking_steps:
                result_text += "\n\n<details>\n"
                result_text += "<summary>分析过程</summary>\n\n"
                result_text += "\n".join(thinking_steps[-5:])
                result_text += "\n</details>"
        else:
            result_text = "未查询到相关数据指标。"
            if thinking_steps:
                result_text += "\n\n分析过程：\n"
                result_text += "\n".join(thinking_steps[-3:])

        return ToolResponse(
            content=[TextBlock(type="text", text=result_text)],
        )

    except Exception as e:
        logger.exception("ChatBI query failed")
        return ToolResponse(
            content=[TextBlock(
                type="text",
                text=f"Error: ChatBI query failed - {e}",
            )],
        )
```

### 5.4 KnowledgeQA 工具：`knowledgeqa.py`

```python
# -*- coding: utf-8 -*-
"""Knowledge base QA tool for querying enterprise documents."""

import logging
from typing import Optional
from urllib.parse import quote_plus

from agentscope.message import TextBlock
from agentscope.tool import ToolResponse

from ...config import load_config

logger = logging.getLogger(__name__)


async def query_knowledge_base(
    query: str,
    session_id: Optional[str] = None,
) -> ToolResponse:
    """Query the enterprise knowledge base for document-backed answers.

    Use this tool when the user asks about company policies, procedures,
    product documentation, operation manuals, industry standards,
    regulations, or any enterprise knowledge content.

    Args:
        query (`str`):
            Natural language question to search in the knowledge base.
        session_id (`Optional[str]`):
            Optional session ID for conversation continuity.

    Returns:
        `ToolResponse`:
            Answer text with referenced document links.
    """
    from ._reception_client import post_sse_stream

    config = load_config()
    reception = getattr(config, "reception", None)
    if reception is None or not reception.knowledge_qa.enabled:
        return ToolResponse(
            content=[TextBlock(
                type="text",
                text="Error: KnowledgeQA is not configured. "
                     "Please set reception.knowledge_qa in config.json.",
            )],
        )

    kqa_cfg = reception.knowledge_qa
    url = kqa_cfg.domain.rstrip("/") + kqa_cfg.endpoint

    import uuid
    payload = {
        "access": kqa_cfg.access,
        "query": query,
        "user_id": "copaw",
        "session_id": session_id or str(uuid.uuid4()),
        "current_session_id": str(uuid.uuid4()),
    }

    try:
        result_text = ""
        docs = []

        async for chunk in post_sse_stream(url, payload):
            if chunk is None:
                continue

            step = chunk.get("step", -1)

            if step == 0:
                if "cite_info" in chunk:
                    docs = chunk["cite_info"]
                else:
                    content = chunk.get("content", "")
                    result_text += content

        # 格式化文档链接
        doc_links = []
        link_tpl = kqa_cfg.doc_link_template
        for doc in (docs or []):
            doc_name = doc.get("doc_name", "未知文档")
            doc_url = doc.get("doc_url", "")
            if doc_url and link_tpl:
                domain = kqa_cfg.domain.replace("/kapi", "")
                full_url = link_tpl.format(
                    domain=domain,
                    oss_path=quote_plus(doc_url),
                )
                doc_links.append(f"- [{doc_name}]({full_url})")
            else:
                doc_links.append(f"- {doc_name}")

        output = result_text.strip() if result_text else "未查询到相关知识。"
        if doc_links:
            output += "\n\n**参考文档：**\n" + "\n".join(doc_links)

        return ToolResponse(
            content=[TextBlock(type="text", text=output)],
        )

    except Exception as e:
        logger.exception("KnowledgeQA query failed")
        return ToolResponse(
            content=[TextBlock(
                type="text",
                text=f"Error: Knowledge base query failed - {e}",
            )],
        )
```

### 5.5 工具注册

**修改 `src/copaw/agents/tools/__init__.py`**：

```python
# 新增导入
from .chatbi import query_chatbi
from .knowledgeqa import query_knowledge_base

# 新增到 __all__
__all__ = [
    # ... 现有工具 ...
    "query_chatbi",
    "query_knowledge_base",
]
```

**修改 `src/copaw/agents/react_agent.py`**：

在文件顶部 import 新增：

```python
from .tools import (
    # ... 现有 imports ...
    query_chatbi,
    query_knowledge_base,
)
```

在 `_create_toolkit()` 的 `tool_functions` 字典中新增：

```python
tool_functions = {
    # ... 现有工具 ...
    "query_chatbi": query_chatbi,
    "query_knowledge_base": query_knowledge_base,
}
```

### 5.6 Skill 文件

#### `agents/skills/reception_chatbi/SKILL.md`

```markdown
---
name: reception_chatbi
description: "数据分析助手 - 通过 ChatBI 服务查询业务指标数据，
  支持指标查询、维度下钻、极值取数、数据对比等。"
metadata:
  copaw:
    emoji: "📊"
---

# ChatBI 数据分析

通过 `query_chatbi` 工具查询业务指标和 KPI 数据。

## 何时使用

当用户问到以下类型问题时，使用 `query_chatbi` 工具：
- 业务指标查询：如"本月门诊接诊人数""今天的收入"
- 维度下钻：如"每个科室的门诊量""按月份的手术台次"
- 极值/排名：如"收入最高的科室""接诊人数排名前五的医生"
- 数据对比：如"今年和去年的门诊收入对比""3月和4月的手术量比较"

## 使用技巧

1. **每次查询不超过 3 个指标**，避免结果过于复杂
2. 如果用户的问题涉及多个维度，可以拆分为多次调用
3. query 参数直接使用用户的自然语言问题即可，ChatBI 会自动解析
4. 返回的数据中如果出现 "-"，表示该指标暂未入库

## 不适用场景

- 不查询互联网开放数据
- 不做统计学分析或机器学习预测
- 不查询政策文件中的指标定义（这类问题请使用 `query_knowledge_base`）
```

#### `agents/skills/reception_knowledgeqa/SKILL.md`

```markdown
---
name: reception_knowledgeqa
description: "知识库问答 - 检索企业知识库文档，提供基于文档的专业回答，
  适用于公司制度、产品文档、操作手册、政策法规等。"
metadata:
  copaw:
    emoji: "📚"
---

# 知识库问答

通过 `query_knowledge_base` 工具检索企业知识库。

## 何时使用

当用户问到以下类型问题时，使用 `query_knowledge_base` 工具：
- 公司制度和流程：如"年假怎么申请""出差报销流程"
- 产品文档：如"门诊病历系统怎么使用""HIS 系统操作手册"
- 行业标准：如"三级医院评审标准""DRG 分组规则"
- 政策法规：如"医疗质量管理办法""电子病历分级标准"
- 指标定义：如"门诊量的计算方式""医疗收入的定义"

## 使用技巧

1. query 参数使用用户的原始问题，知识库会自动做问题扩展和语义匹配
2. 返回结果包含参考文档链接，可以提供给用户作为原始依据
3. 如果问题不清晰，可以先帮用户理清问题再调用

## 不适用场景

- 不回答超出企业知识库范围的问题
- 不检索互联网新闻或开放域知识
- 不适用于健康科普或医疗诊断
- 不查询实时业务数据（数据查询请使用 `query_chatbi`）

## ChatBI vs 知识库 的区分

| 用户问题类型 | 使用工具 |
|-------------|---------|
| 查数据、看指标、数值统计 | `query_chatbi` |
| 查制度、查文档、查规范 | `query_knowledge_base` |
| "门诊收入是多少" (查数值) | `query_chatbi` |
| "门诊收入怎么算" (查定义) | `query_knowledge_base` |
```

---

## 6. 配置设计

### 6.1 Config Schema 扩展

修改 `src/copaw/config/config.py`，新增 reception 配置：

```python
class ChatBIConfig(BaseModel):
    """ChatBI service configuration."""
    enabled: bool = False
    domain: str = ""
    endpoint: str = "/hdos-chat-ai/chatAi/getMessage"
    ws_url: str = ""
    login_info: dict = Field(default_factory=dict)


class KnowledgeQAConfig(BaseModel):
    """KnowledgeQA service configuration."""
    enabled: bool = False
    domain: str = ""
    endpoint: str = "/ai-knowledege/knowledge_qa/streaming"
    access: str = ""
    doc_link_template: str = (
        "{domain}/cfdata/ai-report-center/"
        "ai-niuniu-doc-read?oss_path={oss_path}"
    )


class ReceptionConfig(BaseModel):
    """Reception service integration configuration."""
    chatbi: ChatBIConfig = Field(default_factory=ChatBIConfig)
    knowledge_qa: KnowledgeQAConfig = Field(
        default_factory=KnowledgeQAConfig,
    )
```

在主 `Config` 类中新增字段：

```python
class Config(BaseModel):
    # ... 现有字段 ...
    reception: ReceptionConfig = Field(
        default_factory=ReceptionConfig,
    )
```

### 6.2 config.json 配置示例

```json
{
  "reception": {
    "chatbi": {
      "enabled": true,
      "domain": "https://cfdata-xnyl-poc.cfuture.shop/kapi",
      "endpoint": "/hdos-chat-ai/chatAi/getMessage",
      "ws_url": "wss://chat-bi-xnyl-poc.cfuture.shop/kapi/hdos-chat-ai/websocket/hdos-chat-ai/pcChatBI",
      "login_info": {
        "staffId": "118101",
        "name": "CoPaw",
        "jobNumber": "copaw",
        "orgId": "10000003",
        "orgName": "未来医院"
      }
    },
    "knowledge_qa": {
      "enabled": true,
      "domain": "http://niuniu-test.cfuture.shop",
      "endpoint": "/ai-knowledege/knowledge_qa/streaming",
      "access": "CFPOC",
      "doc_link_template": "{domain}/cfdata/ai-report-center/ai-niuniu-doc-read?oss_path={oss_path}"
    }
  }
}
```

### 6.3 环境变量支持（可选）

适合 Docker 部署场景：

| 环境变量 | 对应配置 |
|----------|---------|
| `RECEPTION_CHATBI_DOMAIN` | `reception.chatbi.domain` |
| `RECEPTION_CHATBI_ENABLED` | `reception.chatbi.enabled` |
| `RECEPTION_KQA_DOMAIN` | `reception.knowledge_qa.domain` |
| `RECEPTION_KQA_ENABLED` | `reception.knowledge_qa.enabled` |
| `RECEPTION_KQA_ACCESS` | `reception.knowledge_qa.access` |

---

## 7. 数据流设计

### 7.1 ChatBI 调用流程

```
用户: "这个月门诊收入多少？"
    │
    ▼
CoPaw ReAct Agent
    │  思考: 用户在问业务数据指标，应使用 query_chatbi 工具
    │  行动: query_chatbi(query="这个月门诊收入多少？")
    │
    ▼
query_chatbi 工具函数
    │  1. 从 config 读取 ChatBI 配置
    │  2. 构造 HTTP POST payload:
    │     {wsUrl, message: "这个月门诊收入多少？", loginInfo, sessionId}
    │  3. POST -> ChatBI SSE 端点
    │  4. 逐 chunk 解析:
    │     - step 1~4: 思维链 (意图解析->结构化->参数->计算)
    │     - cardType chunk: 提取指标数据
    │  5. 格式化为 Markdown 文本
    │
    ▼
CoPaw ReAct Agent
    │  观察: 收到结构化的指标数据
    │  思考: 直接将结果整理后回复用户
    │  行动: 生成最终回复
    │
    ▼
用户收到回复:
    "本月门诊收入为 XXX 万元（截至 2026-03-20）"
```

### 7.2 KnowledgeQA 调用流程

```
用户: "年假怎么申请？"
    │
    ▼
CoPaw ReAct Agent
    │  思考: 用户在问公司制度，应使用 query_knowledge_base 工具
    │  行动: query_knowledge_base(query="年假怎么申请？")
    │
    ▼
query_knowledge_base 工具函数
    │  1. 从 config 读取 KnowledgeQA 配置
    │  2. POST -> KnowledgeQA SSE 端点
    │  3. 逐 chunk 解析:
    │     - step 1~2: 检索+生成过程
    │     - step 0: 最终答案文本 + cite_info 引用文档
    │  4. 格式化: 答案 + 参考文档链接
    │
    ▼
CoPaw ReAct Agent
    │  观察: 收到知识库答案和参考文档
    │  思考: 整理答案回复用户
    │
    ▼
用户收到回复:
    "根据公司制度，年假申请流程如下：...
     参考文档：[员工休假管理办法](link)"
```

### 7.3 混合场景（ReAct 多轮推理）

```
用户: "今年的门诊收入是多少？门诊收入的计算方式是什么？"
    │
    ▼
CoPaw ReAct Agent (ReAct 多轮推理)
    │
    │  [第1轮]
    │  思考: 用户问了两个问题，数据查询用 ChatBI，定义查询用知识库
    │  行动: query_chatbi(query="今年的门诊收入是多少")
    │  观察: 收到门诊收入数据
    │
    │  [第2轮]
    │  思考: 第一个问题已回答，现在处理第二个问题
    │  行动: query_knowledge_base(query="门诊收入的计算方式")
    │  观察: 收到门诊收入定义文档
    │
    │  [第3轮]
    │  思考: 两个问题都已回答，综合回复
    │  行动: 生成最终回复
    │
    ▼
用户收到综合回复
```

---

## 8. 前端适配方案

### 8.1 Config UI

在 Console 前端的 Agent Config 页面，新增 "Reception 服务" 配置区域：

**文件变更**：
- `console/src/api/types/agent.ts` — 新增 `ReceptionConfig` TypeScript 类型
- `console/src/api/modules/agent.ts` — 配置读写接口（复用现有 config API）
- `console/src/pages/Agent/Config/components/ReceptionSettings.tsx` — 新增配置表单组件

**UI 设计**：

```
┌─ Reception 服务集成 ──────────────────────────┐
│                                                │
│  ChatBI 数据分析                                │
│  ┌────────────────────────────────────────┐    │
│  │ [x] 启用                               │    │
│  │ 服务地址: [https://xxx.shop/kapi     ] │    │
│  │ 端点:     [/hdos-chat-ai/chatAi/...  ] │    │
│  │ WS URL:   [wss://chat-bi-xxx.shop/...] │    │
│  └────────────────────────────────────────┘    │
│                                                │
│  知识库问答                                     │
│  ┌────────────────────────────────────────┐    │
│  │ [x] 启用                               │    │
│  │ 服务地址: [http://niuniu-test.shop    ] │    │
│  │ 端点:     [/ai-knowledege/...        ] │    │
│  │ Access:   [CFPOC                     ] │    │
│  └────────────────────────────────────────┘    │
│                                                │
└────────────────────────────────────────────────┘
```

### 8.2 Tools UI

在 Agent Config -> Tools 页面中，新增的两个工具会自动显示在工具列表中（因为已在 `tool_functions` 注册），支持启用/禁用切换。

### 8.3 i18n

`console/src/locales/en.json`:

```json
{
  "reception": {
    "title": "Reception Services",
    "chatbi": {
      "title": "ChatBI Data Analysis",
      "domain": "Service Domain",
      "endpoint": "API Endpoint",
      "wsUrl": "WebSocket URL"
    },
    "knowledgeQa": {
      "title": "Knowledge Base QA",
      "domain": "Service Domain",
      "endpoint": "API Endpoint",
      "access": "Access Code"
    }
  }
}
```

`console/src/locales/zh.json`:

```json
{
  "reception": {
    "title": "Reception 服务集成",
    "chatbi": {
      "title": "ChatBI 数据分析",
      "domain": "服务地址",
      "endpoint": "API 端点",
      "wsUrl": "WebSocket 地址"
    },
    "knowledgeQa": {
      "title": "知识库问答",
      "domain": "服务地址",
      "endpoint": "API 端点",
      "access": "访问码"
    }
  }
}
```

---

## 9. 依赖与环境

### 9.1 Python 依赖

```toml
# pyproject.toml - 新增可选依赖组
[project.optional-dependencies]
reception = [
    "httpx>=0.25.0",
    "ujson>=5.0.0",
]
```

> `httpx` 用于异步 HTTP SSE 流式请求，`ujson` 用于高性能 JSON 解析。两者都是轻量依赖。

### 9.2 网络要求

- CoPaw 运行环境需要能访问 ChatBI 和 KnowledgeQA 的服务端点
- 如果服务在内网，CoPaw 需要部署在同一网络环境或配置代理

### 9.3 reception 服务端无需修改

本方案完全基于 reception 已有的 HTTP API 接口，**不需要修改 reception 任何代码**。

---

## 10. 实施步骤与优先级

### Phase 1: 核心工具接入（P0）

| 步骤 | 内容 | 涉及文件 |
|------|------|---------|
| 1.1 | 新增 `ReceptionConfig` 配置类 | `config/config.py` |
| 1.2 | 实现 `_reception_client.py` SSE 客户端 | `agents/tools/_reception_client.py` |
| 1.3 | 实现 `chatbi.py` 工具 | `agents/tools/chatbi.py` |
| 1.4 | 实现 `knowledgeqa.py` 工具 | `agents/tools/knowledgeqa.py` |
| 1.5 | 工具注册（`__init__.py` + `react_agent.py`） | 两个文件各改几行 |
| 1.6 | 基本测试 | `tests/` |

### Phase 2: Skill 指南（P1）

| 步骤 | 内容 | 涉及文件 |
|------|------|---------|
| 2.1 | 编写 ChatBI SKILL.md | `agents/skills/reception_chatbi/SKILL.md` |
| 2.2 | 编写 KnowledgeQA SKILL.md | `agents/skills/reception_knowledgeqa/SKILL.md` |
| 2.3 | 验证 Skill 加载和 agent 理解度 | 手动测试 |

### Phase 3: 前端配置 UI（P2）

| 步骤 | 内容 | 涉及文件 |
|------|------|---------|
| 3.1 | 新增 TypeScript 类型 | `console/src/api/types/` |
| 3.2 | 新增 ReceptionSettings 组件 | `console/src/pages/Agent/Config/` |
| 3.3 | 新增 i18n 翻译 | `console/src/locales/` |

### Phase 4: 增强功能（P3，可选）

| 步骤 | 内容 |
|------|------|
| 4.1 | 支持 login_info 从频道用户信息自动填充 |
| 4.2 | ChatBI 数据卡片的富文本渲染（Console 前端） |
| 4.3 | 工具调用结果的流式输出（需要 CoPaw 框架层支持） |
| 4.4 | 添加 reception 健康检查 API |

---

## 11. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| ChatBI/KnowledgeQA 服务不可用 | 工具调用超时或报错 | 工具内置超时处理（120s）+ 友好错误提示；agent 会尝试用其他方式回答 |
| SSE 流格式变更 | 解析失败 | `_reception_client.py` 做容错处理，非 JSON 行跳过；关键变更点加日志 |
| login_info 不匹配 | ChatBI 鉴权失败 | 在配置中预设 login_info，或支持从环境变量注入 |
| 工具描述不够精确 | LLM 误判工具选择 | 通过 SKILL.md 补充详细的使用场景说明 + 对比表 |
| httpx 依赖与现有依赖冲突 | 安装失败 | httpx 是轻量标准库，冲突概率低；如有问题可回退到 aiohttp |
| 配置变更不触发工具重载 | 需重启才生效 | 工具每次调用时读取最新 config（`load_config()`），无缓存问题 |
| 工具调用延迟较高（SSE 流式） | 用户等待时间长 | 当前 CoPaw ReAct 循环是同步等待工具结果；P4 阶段可优化为流式输出 |

---

## 12. 测试策略

### 12.1 单元测试

```python
# tests/test_chatbi_tool.py

import pytest
from unittest.mock import AsyncMock, patch


@pytest.mark.asyncio
async def test_chatbi_disabled():
    """ChatBI 未启用时返回错误提示."""
    from copaw.agents.tools.chatbi import query_chatbi
    with patch("copaw.agents.tools.chatbi.load_config") as mock:
        mock.return_value.reception = None
        result = await query_chatbi("test query")
        assert "not configured" in result.content[0].text


@pytest.mark.asyncio
async def test_chatbi_parse_card():
    """ChatBI 正确解析卡片数据."""
    # mock post_sse_stream 返回模拟的 SSE chunks
    ...


@pytest.mark.asyncio
async def test_knowledgeqa_parse_docs():
    """KnowledgeQA 正确解析文档引用."""
    ...
```

### 12.2 集成测试

```python
# tests/test_reception_integration.py

@pytest.mark.slow
@pytest.mark.asyncio
async def test_chatbi_live():
    """对真实 ChatBI 服务的端到端测试（需要网络）."""
    ...

@pytest.mark.slow
@pytest.mark.asyncio
async def test_knowledgeqa_live():
    """对真实 KnowledgeQA 服务的端到端测试（需要网络）."""
    ...
```

### 12.3 Agent 级别测试

手动验证 agent 对以下 prompt 的工具选择准确性：

| 用户输入 | 期望工具 |
|----------|---------|
| "今天的门诊量有多少" | `query_chatbi` |
| "年假怎么申请" | `query_knowledge_base` |
| "门诊收入的计算方式是什么" | `query_knowledge_base` |
| "对比上个月和这个月的手术台次" | `query_chatbi` |
| "帮我写一封邮件" | 不调用 reception 工具 |
| "门诊收入多少？门诊收入怎么计算？" | 先 `query_chatbi` 再 `query_knowledge_base` |

---

## 附录 A: reception 原始数据格式参考

### ChatBI SSE Chunk 格式

**思维链 chunk**:
```json
{"step": 1, "type": 101, "content": "意图解析: 用户想查询..."}
```

**最终卡片 chunk** (单指标):
```json
{
  "cardType": "type1",
  "cardTitle": "门诊收入",
  "pcTemplateForMoreIndicators": [
    {
      "title": "门诊收入",
      "value": 1234567,
      "formatValue": "123.46万",
      "timeValue": "2026-03",
      "metricCode": "MZ_SR"
    }
  ],
  "relationMetricsPermission": []
}
```

### KnowledgeQA SSE Chunk 格式

**过程 chunk**:
```json
{"step": 1, "type": 1, "content": "正在检索相关文档..."}
```

**结果 chunk**:
```json
{"step": 0, "content": "根据《员工休假管理办法》..."}
```

**引用 chunk**:
```json
{
  "step": 0,
  "cite_info": [
    {"doc_name": "员工休假管理办法.pdf", "doc_url": "oss://path/to/doc.pdf"}
  ]
}
```

---

## 附录 B: 为什么不用 MCP

虽然 MCP 是 CoPaw 支持的标准扩展协议，但本场景下不推荐：

1. **额外进程管理**：MCP 需要独立的 server 进程，增加部署复杂度
2. **简单调用**：ChatBI/KnowledgeQA 本质是两个 HTTP API 调用，不需要 MCP 的工具发现、session 管理等复杂能力
3. **配置重复**：MCP config 和 reception 自身配置会有冗余
4. **调试困难**：MCP 的 stdio 通信增加了排查链路

如果未来 reception 发展为平台化服务（工具数量超过 5 个、需要动态工具发现），可以考虑封装为 MCP server。

---

## 附录 C: 后续演进方向

1. **流式输出**：当前 CoPaw 的 ReAct 循环需要等工具返回完整结果才能继续推理。未来可以支持工具函数的流式返回，让用户更早看到 ChatBI 的分析过程。

2. **Channel 用户映射**：从频道消息中提取用户身份信息（如钉钉用户名），自动填充 `login_info`，实现 ChatBI 的按用户权限查询。

3. **数据卡片渲染**：ChatBI 返回的原始卡片数据（`pcTemplateForMoreIndicators`）可以在 Console 前端做富文本/图表渲染，而非纯文本。

4. **Cron 集成**：支持定时触发 ChatBI 查询（如每日推送关键指标），通过 CoPaw 的 CronManager 实现。

5. **记忆增强**：将 ChatBI/KnowledgeQA 的查询结果存入 CoPaw 的长期记忆，支持后续会话中引用历史查询。
