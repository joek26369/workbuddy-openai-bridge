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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) ARG_PORT="${2:-}"; shift 2 ;;
    --password) ARG_PW="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

probe() {  # probe <port> <password>，0 表示可用
  # 判定要点：必须同时出现 "status":"ok" 和 "platforms"。
  # 只看 status 会把适配层自己的 /health 也认成网关（它同样返回 status:ok），
  # 那样扫端口时会误命中 8100 端口。
  local h
  h=$(curl -s --noproxy '*' -m 5 -H "Authorization: Bearer $2" \
        "http://127.0.0.1:$1/api/v1/health" 2>/dev/null)
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

# ---------- 3. 旧口令 + 扫端口（日常最常用） ----------
# 实测结论：WorkBuddy 重启后端口会变（例如 52436 → 64654），但口令不变。
# 所以拿 .gateway.json 里已有的口令，去探当前所有本地监听端口，命中即更新端口。
# 这一步让"重启后必须先手动改配置"变成自动恢复。
if [[ -f "$OUT" ]]; then
  OLD_PW=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('password',''))" "$OUT" 2>/dev/null)
  if [[ -n "$OLD_PW" ]]; then
    SCAN_PORTS=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk '$9 ~ /^127\.0\.0\.1:[0-9]+$/ {split($9,a,":"); print a[2]}' | sort -un)
    for p in $SCAN_PORTS; do
      if probe "$p" "$OLD_PW"; then
        save "$p" "$OLD_PW"
        echo "   （旧口令在新端口上有效，端口已自动更新）"
        exit 0
      fi
    done
  fi
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

# ---------- 失败：给出可执行的下一步 ----------
echo >&2
echo "自动获取失败。你的网关可能是内嵌在桌面端里的，进程环境里拿不到口令。" >&2
echo "请手动指定一次：" >&2
echo >&2
echo "  1) 找端口：" >&2
echo "     lsof -nP -iTCP -sTCP:LISTEN | grep -i workbuddy" >&2
echo >&2
echo "  2) 找口令（二选一）：" >&2
echo "     - 如果之前已经配好过，沿用 .gateway.json 里的旧值" >&2
echo "     - 或从 WorkBuddy 内置网关启动时打印的 Password 行获取" >&2
echo >&2
echo "  3) 写入：" >&2
echo "     ./setup.sh --port <端口> --password <口令>" >&2
exit 1
