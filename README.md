# workbuddy-openai-bridge

**一句话说明：** 这个工具能让别的软件（比如 Cherry Studio、Chatbox、n8n 或者你自己写的脚本）直接调用 WorkBuddy 里的 AI，用法和调用 ChatGPT 一样。它沿用 WorkBuddy 已经登录好的身份，所以不用另外申请 API Key。

> 平台：macOS　适用版本：WorkBuddy 5.9.3 实测通过　依赖：Python 3.8+（只用标准库）

---

## 这个工具解决什么问题

WorkBuddy 是个很能干的桌面 Agent：能读本地文件、写代码、做表格。但它**不提供 API**，也不发 API Key。所以你只能在它自己的窗口里跟它说话，别的工具没法调用它。

而它内部其实跑着一个本地服务，自己跟自己通信。这个项目做的事很简单：

> **找到那个本地服务，借用它的身份，把你的请求翻译成它能听懂的样子。**

于是你就能在任意支持 OpenAI 协议的客户端里，用上 WorkBuddy 背后那套能动手干活的 Agent。

---

## 它是什么 / 不是什么

先说清楚边界，免得白折腾。

**它是什么**

- 一个约 400 行的 Python 脚本，把 OpenAI 的 `/v1/chat/completions` 请求转成 WorkBuddy 内部的调用格式
- 调用方拿到的是 **Agent 的答复**：它会读文件、跑命令、查资料，不只是聊天
- 支持流式（`stream: true`）和非流式两种模式

**它不是什么**

- 不是 WorkBuddy 官方接口，也不代表官方立场
- 不能并发：WorkBuddy 的网关绑定**唯一一个活动对话**，所有外部调用排队往里塞
- 不能隔离：**每次调用都会写进你当前打开的那个对话**，会污染对话历史
- 不是通用方案：只对 macOS 上装了 WorkBuddy 桌面端的机器有效

---

## 工作原理

三步，全部在本机完成：

```
外部工具                    本项目                      WorkBuddy 桌面端
   │                          │                              │
   │  POST /v1/chat/          │                              │
   │  completions  ─────────► │  1. 找到网关端口与口令        │
   │                          │  2. 转成内部消息格式 ───────► │  已登录，能调模型
   │                          │  3. 读回 SSE 流   ◄─────────  │
   │  ◄─────────  OpenAI 格式的答复                            │
```

关键点：**它不去登录，也不碰账号**。它复用桌面端已经认证好的那个网关，所以不用填任何 Key。

---

## 快速开始

### 第一步：装好前提

- 打开 WorkBuddy 桌面端
- **确保有一个打开的对话窗口**（网关只在有活动对话时可用）
- 终端里确认 Python 可用：`python3 --version`

### 第二步：配置网关凭据

```bash
cd workbuddy-openai-bridge
./setup.sh
```

脚本会自动找网关端口和口令，成功会打印：

```
OK 已写入 /path/to/workbuddy-openai-bridge/.gateway.json, 端口 52436
```

绝大多数情况到这一步就结束了。脚本会自己处理三件麻烦事：

1. **重启后端口变了** —— 用已有口令扫一遍本地监听端口，命中就自动改写端口（会重试 6 轮约 30 秒，因为网关在 WorkBuddy 重启后要几十秒才起来）
2. **扫描时不会误伤自己** —— 适配层的 `/health` 也返回 `ok`，脚本靠响应里有没有 `platforms` 字段区分
3. **等不及可以加长** —— `SETUP_ROUNDS=30 ./setup.sh` 会等约 2.5 分钟

只有在**新机器第一次用**，或者**口令被轮换**时，才需要手动给一次：

```bash
# 找端口（注意：网关进程名是 Electron，不是 WorkBuddy，按名字 grep 是空的）
lsof -nP -iTCP -sTCP:LISTEN | grep -iE 'electron|workbuddy'

# 写入（换成本机的真实端口和口令，不要带尖括号）
./setup.sh --port 62044 --password 你的口令
```

口令我拿不到也不该拿到，它在你机器上，只有你自己能取。

### 第三步：启动适配层

```bash
./start.sh -d        # 后台运行，日志写 bridge.log
# 或 ./start.sh      # 前台运行，Ctrl+C 停止
```

看到这行就成功了：

```
后台已启动：pid 12345，日志 /path/to/workbuddy-openai-bridge/bridge.log
```

> **为什么必须这样跑**：适配层要常驻，外部工具随时会来请求。用别的方式临时拉起（比如让某个 AI 会话代跑），进程很容易随会话结束被回收——症状是外部工具报一句莫名的 `Failed to fetch`。`start.sh` 启动的进程挂在你自己的终端下，不受影响。

日常管理：

```bash
./start.sh status    # 在不在跑
./start.sh stop      # 停止
tail -f bridge.log   # 看请求日志
```

### 验证

另开一个终端：

```bash
./check.sh
```

它会依次检查网关、适配层，最后告诉你客户端该怎么填。**这一步不会调用模型**，所以你那个对话窗口不会被写入任何东西。

---

## 客户端怎么填

任何支持 OpenAI 协议的工具，都填这三项：

| 项目 | 值 |
|---|---|
| Base URL | `http://127.0.0.1:8100/v1` |
| API Key | 随便填，不校验（比如 `sk-local`） |
| Model | `workbuddy-agent` |

### Cherry Studio / Chatbox

设置里新增一个「OpenAI 兼容」服务商，把上面三项填进去即可。注意把**超时时间调大**（建议 300 秒以上），Agent 干活比普通模型慢。

### curl

```bash
curl -X POST http://127.0.0.1:8100/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "workbuddy-agent",
    "messages": [{"role": "user", "content": "把当前目录的文件列一下"}]
  }'
```

### Python（openai SDK）

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8100/v1", api_key="sk-local")

resp = client.chat.completions.create(
    model="workbuddy-agent",
    messages=[{"role": "user", "content": "帮我看下这个项目有什么文件"}],
    timeout=300,
)
print(resp.choices[0].message.content)
```

---

## 必读：几个绕不过去的限制

这几条不是「以后会优化」，是当前架构决定的，用之前先认了。

**1. 调用会写进你当前的对话**

WorkBuddy 的网关绑定唯一活动会话，没有隔离机制。你在别的地方调用一次，你自己的对话窗口里就会多出这条消息和回答。

副作用很实际：如果你一边在用 WorkBuddy 干活、一边有程序在调接口，两边会串到一起，回答可能对不上问题。**建议别同时用。**

**2. 只能一次一个**

网关是单会话的，多个请求会排队。别拿它做批量并发任务。

**3. 很慢**

普通模型一两秒回一句，Agent 要规划、读文件、执行、汇总，一次几十秒到几分钟很正常。客户端超时一定要调大。

**4. 桌面端必须开着**

关掉 WorkBuddy，接口立刻失效。这不是后台服务。

**5. 版本升级可能失效**

依赖的是内部接口，不是公开契约。WorkBuddy 升级后如果路由或鉴权变了，需要重新适配。

**6. 历史对话的处理方式**

OpenAI 协议里每轮都会带完整历史，但这个网关不支持「传入历史」。本项目把历史压平成一段文字塞进当前消息里，效果是「接着说」，不是真正的多轮会话状态。

---

## 出问题了看这里

| 现象 | 原因 | 怎么办 |
|---|---|---|
| `找不到已登录的 WorkBuddy 网关` | 桌面端没开，或没有活动对话窗口 | 打开 WorkBuddy，随便点开一个对话 |
| `网关拒绝请求: 401` | 口令不对或已轮换 | 重跑 `./setup.sh`，或手动指定口令 |
| `端口 8100 已被占用` | 适配层已经在跑了 | 不用管，或换个端口 `--port 8101` |
| 一直转圈没有返回 | Agent 在干活，客户端超时太短 | 超时调到 300 秒以上 |
| 回答串了 / 答非所问 | 你同时在用 WorkBuddy，两边写同一个会话 | 停掉一边，别并行 |
| 重启 WorkBuddy 后连不上 | 网关端口会变（口令不变） | 重跑 `./setup.sh`，它会自动扫出新端口 |

排查顺序：先 `./check.sh` 看网关通不通，再看服务端日志。

> 关于「重启后端口变」这条：实测口令在重启后是稳定的，变的只有端口。`setup.sh` 会拿 `.gateway.json` 里已有的口令去探当前所有本地监听端口，命中就自动更新，不需要你手动找出新端口。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `server.py` | 适配层本体，OpenAI 兼容接口 |
| `start.sh` | 启停脚本（前台 / 后台 / 停止 / 状态） |
| `setup.sh` | 找网关端口与口令，写入 `.gateway.json`（含重启后的端口自动发现） |
| `check.sh` | 只读体检，不调用模型 |
| `.gateway.json` | 运行时生成的凭据文件，**已在 .gitignore 里** |
| `.bridge.pid` | `start.sh -d` 的进程号，已在 .gitignore 里 |

服务端的接口：

| 路径 | 说明 |
|---|---|
| `GET /health` | 健康检查，同时报告网关地址 |
| `GET /v1/models` | 返回可用模型（只有 `workbuddy-agent`） |
| `POST /v1/chat/completions` | 主接口，支持 `stream` |

---

## 安全说明

- `.gateway.json` 里存的是**网关口令**，等价于本机 WorkBuddy 的操作权限。已加入 `.gitignore`，别手滑提交。
- 适配层默认只监听 `127.0.0.1`，不对局域网开放。**不建议改成 `0.0.0.0`**——那等于把本机的文件操作能力开放给整个网络。
- 本项目不会上传任何数据，所有流量都在本机回环里。

---

## 许可

本项目采用 [MIT License](LICENSE) 开源。另请注意：

**这是非官方项目**，用的是 WorkBuddy 未公开的内部接口。使用前请自行确认是否符合你所用版本的许可协议，风险自负。

---

## 最后一句

这项目本质是个**权宜之计**：官方没有 API，而我又需要它。

如果你只是想让 AI 帮你看文件、改代码，直接在 WorkBuddy 里说话就够了，不需要这套东西。它存在的唯一理由，是让**别的工具**也能用上这个 Agent。
