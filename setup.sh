#!/bin/bash
# setup.sh —— 找到 WorkBuddy 内置网关的端口与口令，写进 .gateway.json。
#
# 适配层要访问桌面端网关，需要 (port, password)：
#   端口 —— 网关是本地回环服务，用 lsof 就能看到哪个进程在监听。
#   口令 —— Bearer token，由宿主注入，不落盘。
#
# 获取顺序：
#   1) 显式指定 --port / --password
#   2) 环境变量 CODEBUDDY_GATEWAY_PORT / CODEBUDDY_GATEWAY_PASSWORD
#   3) 旧口令 + 扫端口：用 .gateway.json 里已有的口令去探当前所有监听端口
#      —— 实测口令跨重启不变，只有端口会变，这一条是日常最常用的
#   4) 运行中进程的环境变量（ps eww，要求同一用户，不要 sudo）
#
# 用法：
#   ./setup.sh                                  # 自动（走 2、3、4）
#   ./setup.sh --port 52436 --password xxxx     # 手动指定
#
# 说明：本脚本只做只读探测，不会启动任何新网关，也不会改动已有的口令。
# 何时需要重跑：重启 WorkBuddy 桌面端之后（端口或口令可能变）——通常第 3 步就能自动修好。

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/.gateway.json"

ARG_PORT=""
ARG_PW=""
WANT_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) ARG_PORT="${2:-}"; shift 2 ;;
    --password) ARG_PW="${2:-}"; shift 2 ;;
    --switch) SWITCH_PORT="${2:-}"; shift 2 ;;
    --list) WANT_LIST=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

probe_body() {  # probe_body <port> <password>，直接吐出响应体
  curl -s --noproxy '*' -m 5 -H "Authorization: Bearer $2" \
    "http://127.0.0.1:$1/api/v1/health" 2>/dev/null
}

# 防呆：文档里的 <端口> / <口令> 只是占位符，照抄会变成 shell 重定向而报
# "syntax error near unexpected token `newline'"。提前拦下来，说人话。
case "$ARG_PORT$ARG_PW" in
  *"<"*|*">"*)
    echo "参数里还留着尖括号。<端口> / <口令> 只是占位符，请换成真实值，例如：" >&2
    echo "  ./setup.sh --port 62044 --password 你的口令" >&2
    exit 2 ;;
esac

probe() {  # probe <port> <password>，0 表示可用
  # 判定要点：必须同时出现 "status":"ok" 和 "platforms"。
  # 只看 status 会把适配层自己的 /health 也认成网关（它同样返回 status:ok），
  # 那样扫端口时会误命中 8100 端口。
  local h
  h=$(probe_body "$1" "$2")
  [[ "$h" == *'"status":"ok"'* && "$h" == *'"platforms"'* ]]
}

save() {
  printf '{"port": %s, "password": "%s"}\n' "$1" "$2" > "$OUT"
  chmod 600 "$OUT"
  echo "OK 已写入 ${OUT}, 端口 $1"
  echo "   下一步：python3 ${HERE}/server.py --port 8100"
}

listen_ports() {  # listen_ports <pid>
  lsof -nP -iTCP -sTCP:LISTEN -a -p "$1" 2>/dev/null \
    | sed -n 's/.*:\([0-9]\{2,\}\) (LISTEN).*/\1/p'
}

list_gateways() {  # 列出所有活着的网关，附带它绑定的那个对话
  local pw="$1" found=0
  echo "活着的网关（一个窗口一个网关，关掉窗口网关就消失）："
  echo
  for p in $(scan_ports); do
    [[ "$(probe_body "$p" "$pw")" == *'"platforms"'* ]] || continue
    found=1
    local info
    info=$(curl -s --noproxy '*' -m 4 -H "Authorization: Bearer $pw" \
             "http://127.0.0.1:$p/api/v1/sessions" 2>/dev/null \
           | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin).get('data', {}).get('sessions', [])
except Exception:
    d = []
if d:
    s = d[0]
    print('%s（%s 条消息）' % (s.get('name', '未命名'), s.get('messageCount', '?')))
else:
    print('（还没有对话）')
" 2>/dev/null)
    printf '  %-6s %s\n' "$p" "${info:-（读不到会话）}"
  done
  [[ "$found" -eq 0 ]] && echo "  （没有）"
  echo
  echo "选定一个端口后：./setup.sh --port <那个端口> --password <口令>"
}

# ---------- 1. 显式参数 ----------
if [[ -n "$ARG_PORT" && -n "$ARG_PW" ]]; then
  if probe "$ARG_PORT" "$ARG_PW"; then save "$ARG_PORT" "$ARG_PW"; exit 0; fi
  echo "失败：端口 $ARG_PORT 探测不通过，口令可能不对，或网关没在运行。" >&2
  exit 1
fi

# ---------- 2. 环境变量 ----------
if [[ -n "${CODEBUDDY_GATEWAY_PASSWORD:-}" && -n "${CODEBUDDY_GATEWAY_PORT:-}" ]]; then
  if probe "$CODEBUDDY_GATEWAY_PORT" "$CODEBUDDY_GATEWAY_PASSWORD"; then
    save "$CODEBUDDY_GATEWAY_PORT" "$CODEBUDDY_GATEWAY_PASSWORD"; exit 0
  fi
  echo "提示：环境变量里的口令探测失败，继续尝试其它来源。" >&2
fi

# ---------- 3. 旧口令 + 扫端口（日常最常用，带重试） ----------
# 实测结论：WorkBuddy 每次重启端口都会变（52436 → 64654 → 62044），但口令不变。
# 所以拿 .gateway.json 里已有的口令，去探当前所有回环监听端口，命中即更新端口。
#
# 为什么必须重试：重启那一刻网关还没监听，一次扫不到是正常现象，
# uptime 可能只有几十秒。一次就放弃会让用户误以为"配置坏了"。
scan_ports() {
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk '$9 ~ /^127\.0\.0\.1:[0-9]+$/ {split($9,a,":"); print a[2]}' | sort -un
}

OLD_PW=""
if [[ -f "$OUT" ]]; then
  OLD_PW=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('password',''))" "$OUT" 2>/dev/null)
fi

AUTH_SEEN=""   # 扫到"像网关但口令不对"的端口时记下来，用于区分失败原因

# ---------- --switch：切换到这个窗口（口令沿用，不用手抄） ----------
if [[ -n "${SWITCH_PORT:-}" ]]; then
  if [[ -z "$OLD_PW" ]]; then
    echo "还没有口令，先跑一次 ./setup.sh 配置好凭据。" >&2
    exit 1
  fi
  if probe "$SWITCH_PORT" "$OLD_PW"; then
    save "$SWITCH_PORT" "$OLD_PW"
    echo "   （口令沿用，已切到该窗口）"
    exit 0
  fi
  echo "端口 $SWITCH_PORT 探测不通过：窗口可能已经关了，或者那不是网关。" >&2
  echo "用 ./setup.sh --list 看看现在有哪些窗口。" >&2
  exit 1
fi

# ---------- --list：先看清有哪些窗口，再决定接哪个 ----------
if [[ -n "$WANT_LIST" ]]; then
  if [[ -z "$OLD_PW" ]]; then
    echo "还没有口令，没法探测。先跑一次 ./setup.sh 配置好凭据。" >&2
    exit 1
  fi
  list_gateways "$OLD_PW"
  exit 0
fi

if [[ -n "$OLD_PW" ]]; then
  ROUNDS="${SETUP_ROUNDS:-6}"
  for r in $(seq 1 "$ROUNDS"); do
    for p in $(scan_ports); do
      if probe "$p" "$OLD_PW"; then
        save "$p" "$OLD_PW"
        echo "   （旧口令在新端口上有效，端口已自动更新）"
        exit 0
      fi
      body=$(probe_body "$p" "$OLD_PW")
      [[ "$body" == *'AUTH_REQUIRED'* ]] && AUTH_SEEN="$AUTH_SEEN $p"
    done
    if [[ "$r" -lt "$ROUNDS" ]]; then
      printf '   第 %s/%s 轮没扫到可用网关，5 秒后重试（WorkBuddy 重启后网关要几十秒才起来）…\n' \
        "$r" "$ROUNDS"
      sleep 5
    fi
  done
fi

# ---------- 4. 从进程环境读 ----------
# 网关有两种承载方式：
#   a) 独立的 codebuddy --serve 子进程 —— 环境里有 CODEBUDDY_GATEWAY_PASSWORD
#   b) WorkBuddy 桌面端内嵌（Electron 主进程）—— 环境里通常没有口令
PIDS=$({ pgrep -f "cli/bin/codebuddy --serve" 2>/dev/null
         pgrep -f "codebuddy --serve" 2>/dev/null
         pgrep -x "WorkBuddy" 2>/dev/null
         pgrep -f "WorkBuddy.app/Contents/MacOS" 2>/dev/null
       } | sort -u | tr '\n' ' ')

if [[ -z "${PIDS// /}" ]]; then
  echo "提示：没找到 WorkBuddy 相关进程。" >&2
  echo "      请先打开 WorkBuddy 桌面端并保持一个对话窗口，然后重跑本脚本。" >&2
  exit 1
fi

for pid in $PIDS; do
  ports=$(listen_ports "$pid")
  [[ -z "$ports" ]] && continue
  pw=$(ps eww -p "$pid" 2>/dev/null \
       | sed -n 's/.*CODEBUDDY_GATEWAY_PASSWORD=\([^ ]*\).*/\1/p')
  [[ -z "$pw" ]] && continue
  for p in $ports; do
    if probe "$p" "$pw"; then save "$p" "$pw"; exit 0; fi
  done
done

# ---------- 失败：分两种情形，各给可照抄的命令 ----------
echo >&2
if [[ -n "$AUTH_SEEN" ]]; then
  # 扫到了网关，但口令被拒 —— 说明口令轮换了（WorkBuddy 升级或重新登录后少见地会出现）
  echo "找到 WorkBuddy 网关（端口${AUTH_SEEN}），但 .gateway.json 里的口令已被拒绝。" >&2
  echo "说明口令轮换了，需要你从桌面端取一次新口令：" >&2
  echo >&2
  echo "  1) 在 WorkBuddy 里随便发一条消息，让网关打印出带 Password 的启动信息" >&2
  echo "  2) 用新口令写入（把下面两个值换成你自己的，不要带尖括号）：" >&2
  echo "     ./setup.sh --port 62044 --password 这里填你的新口令" >&2
  echo >&2
  echo "  现在扫到的网关端口是：$(echo $AUTH_SEEN)" >&2
else
  # 完全没扫到网关 —— 这才是最常见的情形
  echo "没扫到 WorkBuddy 网关。这通常不是配置问题，是网关此刻没在监听。" >&2
  echo >&2
  echo "  最常见的原因（按概率排序）：" >&2
  echo "    1. WorkBuddy 刚重启过，网关要几十秒才起来 —— 等半分钟直接重跑 ./setup.sh" >&2
  echo "    2. WorkBuddy 开着但没有活动的对话窗口 —— 点开任意一个对话" >&2
  echo "    3. WorkBuddy 根本没开 —— 先启动它" >&2
  echo >&2
  echo "  想确认网关到底在不在，用这条（网关进程名是 Electron，不是 WorkBuddy，所以按名字 grep 是空的）：" >&2
  echo "     lsof -nP -iTCP -sTCP:LISTEN | grep -iE 'electron|workbuddy'" >&2
  echo >&2
  echo "  想让它等更久再放弃（例如 30 轮 ≈ 2.5 分钟）：" >&2
  echo "     SETUP_ROUNDS=30 ./setup.sh" >&2
fi
exit 1
