#!/bin/bash
# start.sh —— 适配层的启停脚本。
#
# 为什么需要它：适配层必须常驻，外部工具（浏览器扩展等）随时会来请求。
# 实测教训：由 Agent 沙箱临时拉起的进程活不过那一轮会话，用户点"测试连通"
# 时服务已经死了，浏览器只报一句莫名的 "Failed to fetch"。
# 所以：服务必须由你在自己的终端里启动，进程归你的终端会话所有。
#
# 用法：
#   ./start.sh          前台运行（日志直接打到屏幕，Ctrl+C 停止）
#   ./start.sh -d       后台运行（nohup，日志写 bridge.log）
#   ./start.sh stop     停止后台实例
#   ./start.sh status   看是否在跑

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${BRIDGE_PORT:-8100}"
LOG="$HERE/bridge.log"
PIDFILE="$HERE/.bridge.pid"

is_running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-}" in
  stop)
    if is_running; then
      PID="$(cat "$PIDFILE")"
      kill "$PID" && rm -f "$PIDFILE"
      echo "已停止（pid $PID）"
    else
      rm -f "$PIDFILE"
      # 兜底：没有 pidfile 但端口被旧的 server.py 占着
      pkill -f "server.py --port $PORT" 2>/dev/null
      echo "没有在跑的实例（已清理可能的残留进程）"
    fi
    exit 0 ;;
  status)
    if is_running; then
      echo "在跑：pid $(cat "$PIDFILE")，http://127.0.0.1:$PORT/v1"
    else
      echo "没在跑。启动：./start.sh -d"
    fi
    exit 0 ;;
esac

if is_running; then
  echo "已经在跑了（pid $(cat "$PIDFILE")），不用重复启动。"
  exit 0
fi

# 启动前先确认网关配置就绪，缺了现场跑一次 setup.sh
if ! python3 - "$HERE/.gateway.json" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("port") and d.get("password")
PY
then
  echo "还没配置网关凭据，先跑 setup.sh …"
  "$HERE/setup.sh" || exit 1
fi

echo "OpenAI 兼容接口 → http://127.0.0.1:$PORT/v1   （model: workbuddy-agent）"

if [[ "${1:-}" == "-d" ]]; then
  cd "$HERE"
  nohup python3 server.py --port "$PORT" > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "后台已启动：pid $(cat "$PIDFILE")，日志 $LOG"
  else
    echo "启动失败，日志最后几行：" >&2
    tail -5 "$LOG" >&2
    exit 1
  fi
else
  cd "$HERE"
  exec python3 server.py --port "$PORT"
fi
