#!/usr/bin/env python3
"""
server.py —— 把 WorkBuddy 桌面端自带的 Agent 网关包装成 OpenAI 兼容接口，
供外部工具（Cherry Studio / Chatbox / n8n / 自写脚本 等）调用。

为什么这样做（实测结论，不是推测）：

  1. WorkBuddy 不对外提供 OpenAI 兼容服务，也不发 API Key。
  2. 包内 CLI 可以单独 `--serve`，但**全新进程拿不到模型凭据**：
     登录 token 只存在于桌面端（Electron）拉起的那一个 CLI 进程内存里，
     不落盘（~/.codebuddy 下无凭据文件），所以 `-p` / 新起的 serve 都会报
     AuthenticationRequiredError。
  3. 桌面端自己的网关是已认证的，地址形如 http://127.0.0.1:<port>，
     Bearer 口令在 spawn 时通过环境变量 CODEBUDDY_GATEWAY_PASSWORD 注入。
  4. 该网关**绑定唯一活动会话**：/api/v1/runs 的消息会写进当前对话；
     /api/v1/jobs（后台 agent）另起进程 → 同样认证失败；
     /api/v1/sessions/{id}/reply 对非活动会话返回 SESSION_FOLLOW_NOT_LIVE。
     所以隔离做不到 —— 每次外部调用都会落进当前对话。

调用链：
    POST /api/v1/runs   {"id","type":"message","payload":{"text"}}
    → {"data":{"runId":...}}
    GET  /api/v1/runs/{runId}/stream   (SSE)
    → event: message  data: {"content":{"markdown":"..."}}   ← 最终答复
    → event: done

用法：
    python3 server.py --port 8100
    # 外部工具填 base_url = http://127.0.0.1:8100/v1 ，模型名 workbuddy-agent

网关发现顺序：
    a) .gateway.json（{"port":52436,"password":"..."}）
    b) 环境变量 CODEBUDDY_GATEWAY_PORT / CODEBUDDY_GATEWAY_PASSWORD
    c) 自动扫描：找到 cli/bin/codebuddy --serve 的进程 → lsof 取监听端口，
       ps eww 取口令（需与桌面端同一用户；不要用 sudo）
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_NAME = "workbuddy-agent"
DEFAULT_TIMEOUT = 600          # Agent 单次执行上限（秒）
HERE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(HERE, ".gateway.json")

# 绕过系统全局代理：本机回环不经过 proxy
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


# ---------------------------------------------------------------- 网关发现

def _candidates_from_env():
    port = os.environ.get("CODEBUDDY_GATEWAY_PORT", "").strip()
    pw = os.environ.get("CODEBUDDY_GATEWAY_PASSWORD", "").strip()
    if port and pw:
        return [(int(port), pw)]
    return []


def _candidates_from_state():
    try:
        with open(STATE_FILE) as f:
            d = json.load(f)
        if d.get("port") and d.get("password"):
            return [(int(d["port"]), d["password"])]
    except Exception:
        pass
    return []


def _run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def _candidates_from_process():
    """找到桌面端拉起的 codebuddy --serve 进程，取端口与口令。"""
    out = []
    env_pw = os.environ.get("CODEBUDDY_GATEWAY_PASSWORD", "").strip()
    pids = set()
    for pat in ("cli/bin/codebuddy --serve", "codebuddy --serve"):
        for line in _run(["pgrep", "-f", pat]).splitlines():
            line = line.strip()
            if line.isdigit():
                pids.add(line)
    for pid in pids:
        ports = []
        for line in _run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid]).splitlines()[1:]:
            m = re.search(r":(\d+)\s+\(LISTEN\)", line)
            if m:
                ports.append(int(m.group(1)))
        pw = env_pw
        if not pw:
            m = re.search(r"CODEBUDDY_GATEWAY_PASSWORD=(\S+)", _run(["ps", "eww", "-p", pid]))
            if m:
                pw = m.group(1)
        for p in ports:
            if pw:
                out.append((p, pw))
    return out


def _candidates_from_scan(known_pw):
    """拿已有口令扫一遍本地监听端口。

    为什么需要：WorkBuddy 每次重启，网关端口都会换（实测 52436 → 64654 →
    62044 → 50397 → 61875），但口令不变。只依赖 .gateway.json 里的端口，
    重启之后每个请求都会 502 Connection refused，而用户完全不知道为什么。
    """
    if not known_pw:
        return []
    ports = []
    for line in _run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"]).splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        name = parts[8]
        if not name.startswith("127.0.0.1:"):
            continue
        try:
            ports.append(int(name.rsplit(":", 1)[1]))
        except ValueError:
            pass
    return [(p, known_pw) for p in sorted(set(ports))]


def _existing_service(port, timeout=3):
    """端口被占用时看一眼是不是本服务已经在跑。"""
    try:
        with _OPENER.open(f"http://127.0.0.1:{port}/health", timeout=timeout) as r:
            d = json.loads(r.read().decode())
        if d.get("model") == MODEL_NAME:
            return d
    except Exception:
        pass
    return None


def _probe(port, pw, timeout=4):
    """确认 (port, password) 是一台可用的 CodeBuddy 网关。"""
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/v1/health",
        headers={"Authorization": "Bearer " + pw},
    )
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            d = json.loads(r.read().decode())
        if (d.get("data") or {}).get("status") == "ok":
            return True
    except Exception:
        pass
    return False


class _Unreachable(Exception):
    """网关端口连不上（WorkBuddy 重启导致端口变化时触发）。"""


class Gateway:
    def __init__(self):
        self.port = None
        self.password = None
        self.lock = threading.Lock()

    def discover(self, force=False):
        with self.lock:
            if self.port and not force:
                return self.port, self.password
            state = _candidates_from_state()
            cands = state + _candidates_from_env() + _candidates_from_process()
            for port, pw in cands:
                if _probe(port, pw):
                    self.port, self.password = port, pw
                    print(f"[gateway] 命中 127.0.0.1:{port}", flush=True)
                    return port, pw
            # 全部落空：拿已知口令去扫监听端口（端口变了但口令没变的情况）
            known_pw = state[0][1] if state else os.environ.get(
                "CODEBUDDY_GATEWAY_PASSWORD", "").strip()
            for port, pw in _candidates_from_scan(known_pw):
                if _probe(port, pw, timeout=2):
                    self.port, self.password = port, pw
                    print(f"[gateway] 扫到新端口 127.0.0.1:{port}", flush=True)
                    return port, pw
            self.port = self.password = None
            return None, None

    def headers(self):
        return {
            "Authorization": "Bearer " + (self.password or ""),
            "Content-Type": "application/json",
            "x-codebuddy-request": "1",
        }

    def run(self, prompt, timeout=DEFAULT_TIMEOUT):
        """提交一次 Agent 执行，返回 (最终文本, 元信息)。

        端口失效（WorkBuddy 重启后端口会变）时自动重扫并重试一次。
        否则每个请求都是 502 Connection refused，而外部客户端只会显示
        一句莫名其妙的报错，用户完全不知道是端口变了。
        只在提交阶段就连不上时重试——已经拿到 runId 之后失败不重试，
        避免同一条消息被提交两次、在对话里出现重复。
        """
        try:
            return self._run_once(prompt, timeout)
        except _Unreachable as e:
            print(f"[gateway] 端口 {self.port} 连不上（{e}），重新扫描…", flush=True)
            self.port = self.password = None
            port, _ = self.discover(force=True)
            if not port:
                raise RuntimeError(
                    "找不到已登录的 WorkBuddy 网关。请确认 WorkBuddy 桌面端正在运行，"
                    "并且有打开的对话窗口。"
                )
            return self._run_once(prompt, timeout)

    def _run_once(self, prompt, timeout):
        port, pw = self.discover()
        if not port:
            raise RuntimeError(
                "找不到已登录的 WorkBuddy 网关。请确认 WorkBuddy 桌面端正在运行，"
                "并且有打开的对话窗口。"
            )
        msg_id = "ext-" + uuid.uuid4().hex[:12]
        body = {
            "id": msg_id,
            "type": "message",
            "source": {
                "platform": "generic",
                "sender": {"id": "openai-bridge", "name": "openai-bridge"},
                "conversation": {"id": "openai-bridge", "type": "direct"},
            },
            "payload": {"text": prompt},
        }
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/v1/runs",
            data=json.dumps(body).encode(),
            headers=self.headers(), method="POST",
        )
        try:
            with _OPENER.open(req, timeout=30) as r:
                d = json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"网关拒绝请求: {e.code} {e.read()[:200].decode(errors='replace')}")
        except urllib.error.URLError as e:
            # 连接被拒 / 端口没人监听 —— 典型的“WorkBuddy 重启后端口变了”
            raise _Unreachable(str(e.reason))
        run_id = (d.get("data") or {}).get("runId")
        if not run_id:
            raise RuntimeError(f"网关未返回 runId: {d}")

        stream_req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/v1/runs/{run_id}/stream",
            headers={"Authorization": "Bearer " + pw, "Accept": "text/event-stream"},
        )
        text_parts, meta = [], {}
        deadline = time.time() + timeout
        with _OPENER.open(stream_req, timeout=timeout) as r:
            while time.time() < deadline:
                raw = r.readline()
                if not raw:
                    break
                line = raw.decode(errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if not payload:
                    continue
                try:
                    ev = json.loads(payload)
                except Exception:
                    continue
                content = ev.get("content") or {}
                if content.get("markdown"):
                    text_parts.append(content["markdown"])
                if ev.get("agent"):
                    meta = ev["agent"]
                if ev.get("status") in ("completed", "failed", "error"):
                    break
        return ("".join(text_parts), meta)


GW = Gateway()


# ---------------------------------------------------------------- OpenAI 适配

def flatten(messages):
    """把 OpenAI messages 压平成一段 prompt，保留角色与历史。"""
    sys_parts, turns = [], []
    for m in messages or []:
        role = m.get("role", "user")
        content = m.get("content", "")
        if isinstance(content, list):  # 多模态数组
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        if role == "system":
            sys_parts.append(content)
        elif role == "assistant":
            turns.append(f"[assistant] {content}")
        elif role == "tool":
            turns.append(f"[tool] {content}")
        else:
            turns.append(f"[user] {content}")
    parts = []
    if sys_parts:
        parts.append("以下是调用方设定的系统指令，请在本轮对话中遵循：\n" + "\n".join(sys_parts))
    if len(turns) > 1:
        parts.append("以下是此前的对话记录：\n" + "\n".join(turns[:-1]))
    if turns:
        parts.append(turns[-1])
    return "\n\n".join(p for p in parts if p)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "workbuddy-openai-bridge/3.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _sse_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def _sse(self, obj):
        self.wfile.write(b"data: " + json.dumps(obj, ensure_ascii=False).encode() + b"\n\n")
        self.wfile.flush()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/health", "/"):
            port, _ = GW.discover()
            return self._json(200, {
                "status": "ok",
                "model": MODEL_NAME,
                "gateway": (f"127.0.0.1:{port}" if port else None),
                "note": "调用会写入 WorkBuddy 当前活动对话",
            })
        if path == "/v1/models":
            return self._json(200, {
                "object": "list",
                "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "workbuddy"}],
            })
        return self._json(404, {"error": {"message": f"未知路径 {path}"}})

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._json(400, {"error": {"message": "请求体不是合法 JSON"}})

        if path not in ("/v1/chat/completions", "/chat/completions"):
            return self._json(404, {"error": {"message": f"未知路径 {path}"}})

        prompt = flatten(body.get("messages"))
        if not prompt.strip():
            return self._json(400, {"error": {"message": "messages 为空"}})

        model = body.get("model") or MODEL_NAME
        stream = bool(body.get("stream"))
        cid = "chatcmpl-" + uuid.uuid4().hex[:24]
        created = int(time.time())

        if not stream:
            try:
                text, meta = GW.run(prompt, timeout=DEFAULT_TIMEOUT)
            except Exception as e:
                return self._json(502, {"error": {"message": str(e), "type": "gateway_error"}})
            return self._json(200, {
                "id": cid, "object": "chat.completion", "created": created, "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
                "_meta": meta,
            })

        # 流式：Agent 一次性返回整段，这里按单块增量输出，保证客户端兼容
        self._sse_start()
        try:
            self._sse({"id": cid, "object": "chat.completion.chunk", "created": created,
                       "model": model,
                       "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
            text, _ = GW.run(prompt, timeout=DEFAULT_TIMEOUT)
            self._sse({"id": cid, "object": "chat.completion.chunk", "created": created,
                       "model": model,
                       "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]})
            self._sse({"id": cid, "object": "chat.completion.chunk", "created": created,
                       "model": model,
                       "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except Exception as e:
            try:
                self._sse({"error": {"message": str(e), "type": "gateway_error"}})
            except Exception:
                pass


def main():
    ap = argparse.ArgumentParser(description="WorkBuddy Agent → OpenAI 兼容适配层")
    ap.add_argument("--port", type=int, default=8100)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    port, _ = GW.discover()
    if port:
        print(f"网关就绪：http://127.0.0.1:{port}（口令已取到）", flush=True)
    else:
        print("警告：暂未找到已登录网关。请先打开 WorkBuddy 桌面端并保持一个对话窗口。\n"
              "      服务仍会启动，每次请求会重新尝试发现网关。", flush=True)

    try:
        srv = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as e:
        if getattr(e, "errno", None) in (48, 98):   # EADDRINUSE
            info = _existing_service(args.port)
            print(f"端口 {args.port} 已被占用。", flush=True)
            if info:
                print("  占用它的就是本服务，已经在跑，不需要再启动一次：", flush=True)
                print("  " + json.dumps(info, ensure_ascii=False), flush=True)
            else:
                print("  被其它程序占用。换一个端口即可，例如：", flush=True)
                print(f"  python3 server.py --port {args.port + 1}", flush=True)
            sys.exit(2)
        raise
    print(f"OpenAI 兼容接口已启动：http://{args.host}:{args.port}/v1", flush=True)
    print(f"  base_url = http://{args.host}:{args.port}/v1    model = {MODEL_NAME}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")


if __name__ == "__main__":
    main()
