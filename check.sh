#!/bin/bash
# check.sh —— 体检：确认网关可用、适配层可用。
# 只做只读探测，不调用模型，不往对话里写任何东西。
#
# 用法：./check.sh [适配层端口，默认 8100]

set -uo pipefail
PORT="${1:-8100}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HERE/.gateway.json"

probe() {  # probe <port> <password>
  local h
  h=$(curl -s --noproxy '*' -m 5 -H "Authorization: Bearer $2" \
        "http://127.0.0.1:$1/api/v1/health" 2>/dev/null)
  [[ "$h" == *'"status":"ok"'* ]]
}

listen_ports() {  # listen_ports <pid>
  lsof -nP -iTCP -sTCP:LISTEN -a -p "$1" 2>/dev/null \
    | sed -n 's/.*:\([0-9]\{2,\}\) (LISTEN).*/\1/p'
}

GW_PORT=""
GW_PW=""
GW_SRC=""

# ① .gateway.json
echo "1) 读取 .gateway.json"
if [[ -f "$STATE" ]]; then
  P=$(python3 -c "import json;print(json.load(open('$STATE')).get('port',''))" 2>/dev/null)
  W=$(python3 -c "import json;print(json.load(open('$STATE')).get('password',''))" 2>/dev/null)
  if [[ -n "$P" && -n "$W" ]] && probe "$P" "$W"; then
    GW_PORT="$P"; GW_PW="$W"; GW_SRC=".gateway.json"
    echo "   OK 端口 $P 可用"
  else
    echo "   文件存在但探测失败（端口变了，或口令已轮换）"
  fi
else
  echo "   没有 .gateway.json，先跑 ./setup.sh"
fi

# ② 环境变量
if [[ -z "$GW_PORT" ]]; then
  echo "2) 环境变量"
  if [[ -n "${CODEBUDDY_GATEWAY_PORT:-}" && -n "${CODEBUDDY_GATEWAY_PASSWORD:-}" ]]; then
    if probe "$CODEBUDDY_GATEWAY_PORT" "$CODEBUDDY_GATEWAY_PASSWORD"; then
      GW_PORT="$CODEBUDDY_GATEWAY_PORT"; GW_PW="$CODEBUDDY_GATEWAY_PASSWORD"; GW_SRC="env"
      echo "   OK 端口 $GW_PORT 可用"
    else
      echo "   有变量但探测失败"
    fi
  else
    echo "   未设置"
  fi
fi

# ③ 进程环境
if [[ -z "$GW_PORT" ]]; then
  echo "3) 进程环境"
  PIDS=$({ pgrep -f "cli/bin/codebuddy --serve" 2>/dev/null
           pgrep -f "codebuddy --serve" 2>/dev/null
           pgrep -x "WorkBuddy" 2>/dev/null
           pgrep -f "WorkBuddy.app/Contents/MacOS" 2>/dev/null
         } | sort -u | tr '\n' ' ')
  if [[ -z "${PIDS// /}" ]]; then
    echo "   没找到 WorkBuddy 进程，请先打开桌面端"
  else
    FOUND=0
    for pid in $PIDS; do
      ports=$(listen_ports "$pid")
      [[ -z "$ports" ]] && continue
      pw=$(ps eww -p "$pid" 2>/dev/null | sed -n 's/.*CODEBUDDY_GATEWAY_PASSWORD=\([^ ]*\).*/\1/p')
      [[ -z "$pw" ]] && continue
      for p in $ports; do
        if probe "$p" "$pw"; then
          GW_PORT="$p"; GW_PW="$pw"; GW_SRC="process:$pid"; FOUND=1; break 2
        fi
      done
    done
    [[ "$FOUND" -eq 1 ]] && echo "   OK 端口 $GW_PORT 可用" || echo "   进程环境里没有口令（内嵌网关的常见情况）"
  fi
fi

if [[ -z "$GW_PORT" ]]; then
  echo
  echo "结论：网关未就绪。"
  echo "  → 确认 WorkBuddy 桌面端开着、有打开的对话窗口"
  echo "  → 然后跑 ./setup.sh --port <端口> --password <口令>"
  exit 1
fi

echo
echo "4) 适配层（端口 ${PORT}）"
A=$(curl -s --noproxy '*' -m 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null)
if [[ -n "$A" ]]; then
  echo "   OK $A"
else
  echo "   未启动。运行："
  echo "     cd ${HERE} && python3 server.py --port ${PORT}"
fi

echo
echo "结论：网关已就绪（来源 ${GW_SRC}）"
echo "  外部工具填："
echo "    base_url = http://127.0.0.1:${PORT}/v1"
echo "    api_key  = 任意字符串"
echo "    model    = workbuddy-agent"
echo
echo "  注意：每次调用都会写进 WorkBuddy 当前活动对话。"
