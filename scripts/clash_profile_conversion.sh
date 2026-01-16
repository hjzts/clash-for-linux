#!/usr/bin/env bash
set -euo pipefail

# 作用：
# - 将订阅内容转换成 Clash Meta / Mihomo 可用的完整 YAML 配置
# - 默认使用 subconverter HTTP /sub 接口（最稳）
# - 失败则跳过，不影响主流程
#
# 输入/输出约定：
# - IN_FILE：原订阅（默认 temp/clash.yaml）
# - OUT_FILE：转换后的配置（默认 temp/clash_config.yaml）
#
# 设计原则：
# - 绝不 exit 1（失败只 warn 并 exit 0）
# - 已是完整 Clash 配置则直接 copy
# - 没有 CLASH_URL（原始订阅 URL）则不转换（subconverter 最稳是 url=...）

Server_Dir="${Server_Dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
Temp_Dir="${Temp_Dir:-$Server_Dir/temp}"

mkdir -p "$Temp_Dir"

IN_FILE="${IN_FILE:-$Temp_Dir/clash.yaml}"
OUT_FILE="${OUT_FILE:-$Temp_Dir/clash_config.yaml}"

# “更先进”的默认：Clash Meta / Mihomo
SUB_TARGET="${SUB_TARGET:-clashmeta}"   # 推荐 clashmeta（兼容面最广）
SUB_UDP="${SUB_UDP:-true}"
SUB_EMOJI="${SUB_EMOJI:-true}"
SUB_SORT="${SUB_SORT:-true}"

# 订阅原始 URL（你 .env 里 export CLASH_URL=...）
SUB_URL="${CLASH_URL:-}"

# 0) 输入不存在就跳过
if [ ! -s "$IN_FILE" ]; then
  echo "[WARN] no input file: $IN_FILE"
  exit 0
fi

# 1) 如果看起来已经是完整 Clash 配置，就直接用，不转换
#    （包含 proxies / proxy-providers / rules / port 等任一关键词即可认为是完整配置）
if grep -qE '^(proxies:|proxy-providers:|mixed-port:|port:|rules:|dns:)' "$IN_FILE"; then
  cp -f "$IN_FILE" "$OUT_FILE"
  echo "[OK] input already looks like a Clash config -> $OUT_FILE"
  exit 0
fi

# 2) subconverter 不可用就跳过
if [ "${SUBCONVERTER_READY:-false}" != "true" ] || [ -z "${SUBCONVERTER_URL:-}" ]; then
  echo "[WARN] subconverter not ready, skip conversion"
  exit 0
fi

# 3) 没有原始 URL 就不转（subconverter 最稳是 url=... 拉取）
if [ -z "${SUB_URL:-}" ]; then
  echo "[WARN] CLASH_URL empty, cannot convert via /sub?url=..., skip"
  exit 0
fi

TMP_OUT="$Temp_Dir/.clash_config.converted.yaml"
rm -f "$TMP_OUT" 2>/dev/null || true

# 4) 拼接 /sub 参数（尽量通用）
CONVERT_URL="${SUBCONVERTER_URL}/sub?target=${SUB_TARGET}&url=${SUB_URL}"
if [ "$SUB_UDP" = "true" ]; then CONVERT_URL="${CONVERT_URL}&udp=true"; fi
if [ "$SUB_EMOJI" = "true" ]; then CONVERT_URL="${CONVERT_URL}&emoji=true"; fi
if [ "$SUB_SORT" = "true" ]; then CONVERT_URL="${CONVERT_URL}&sort=true"; fi

# 5) 执行转换（失败则回退）
set +e
curl -fsSL --connect-timeout 3 -m 25 "$CONVERT_URL" -o "$TMP_OUT"
rc=$?
set -e

if [ "$rc" -ne 0 ] || [ ! -s "$TMP_OUT" ]; then
  echo "[WARN] convert failed (rc=$rc), keep original"
  rm -f "$TMP_OUT" 2>/dev/null || true
  exit 0
fi

mv -f "$TMP_OUT" "$OUT_FILE"
echo "[OK] converted via subconverter -> $OUT_FILE (target=${SUB_TARGET})"

true