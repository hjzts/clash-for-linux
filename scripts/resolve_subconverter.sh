#!/usr/bin/env bash
set -euo pipefail

# 作用：
# - 检测 tools/subconverter/subconverter 是否存在
# -（可选）以 daemon 模式启动本地 subconverter（HTTP 服务）
# - 导出统一变量给后续脚本使用：
#   SUBCONVERTER_BIN / SUBCONVERTER_READY / SUBCONVERTER_URL
#
# 设计原则：
# - 永不 exit 1（不可用就 Ready=false，主流程继续）
# - 不阻塞 start.sh（快速启动，不等待健康检查）

Server_Dir="${Server_Dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
Temp_Dir="${Temp_Dir:-$Server_Dir/temp}"

mkdir -p "$Temp_Dir"

Subconverter_Bin="$Server_Dir/tools/subconverter/subconverter"
Subconverter_Ready=false

# 配置项（可放 .env）
SUBCONVERTER_MODE="${SUBCONVERTER_MODE:-daemon}"     # daemon | off
SUBCONVERTER_HOST="${SUBCONVERTER_HOST:-127.0.0.1}"
SUBCONVERTER_PORT="${SUBCONVERTER_PORT:-25500}"
SUBCONVERTER_URL="${SUBCONVERTER_URL:-http://${SUBCONVERTER_HOST}:${SUBCONVERTER_PORT}}"

# pref.ini：不存在就从示例生成
SUBCONVERTER_PREF="${SUBCONVERTER_PREF:-$Server_Dir/tools/subconverter/pref.ini}"
PREF_EXAMPLE_INI="$Server_Dir/tools/subconverter/pref.example.ini"

PID_FILE="$Temp_Dir/subconverter.pid"

# 1) 二进制存在性
if [ -x "$Subconverter_Bin" ]; then
  Subconverter_Ready=true
else
  Subconverter_Ready=false
fi

# 2) pref.ini 生成（仅当准备启用 daemon）
if [ "$Subconverter_Ready" = "true" ] && [ "$SUBCONVERTER_MODE" = "daemon" ]; then
  if [ ! -f "$SUBCONVERTER_PREF" ] && [ -f "$PREF_EXAMPLE_INI" ]; then
    cp -f "$PREF_EXAMPLE_INI" "$SUBCONVERTER_PREF"
  fi
fi

# 3) daemon 启动（只在需要时）
if [ "$Subconverter_Ready" = "true" ] && [ "$SUBCONVERTER_MODE" = "daemon" ]; then
  # pid 存活则认为已启动
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    :
  else
    # 端口已监听则不重复起（可能是之前启动的）
    if command -v ss >/dev/null 2>&1 && ss -lnt | awk '{print $4}' | grep -q ":${SUBCONVERTER_PORT}\$"; then
      :
    else
      (
        cd "$Server_Dir/tools/subconverter"
        # 注意：subconverter 读取 base/rules/snippets 等目录，必须在其目录下启动更稳
        nohup "$Subconverter_Bin" -f "$SUBCONVERTER_PREF" >/dev/null 2>&1 &
        echo $! > "$PID_FILE"
      )
      # 给一点点启动时间（不要长等，避免阻塞）
      sleep 0.2
    fi
  fi
fi

# 4) 统一导出（给后续脚本用）
export Subconverter_Bin
export Subconverter_Ready
export SUBCONVERTER_BIN="$Subconverter_Bin"
export SUBCONVERTER_READY="$Subconverter_Ready"
export SUBCONVERTER_URL

# 永不失败
true