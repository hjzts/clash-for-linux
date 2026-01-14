#!/bin/bash
set -euo pipefail

# =========================
# 基础参数
# =========================
Server_Dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
Install_Dir="${CLASH_INSTALL_DIR:-/opt/clash-for-linux}"
Service_Name="clash-for-linux"
Service_User="${CLASH_SERVICE_USER:-clash}"
Service_Group="${CLASH_SERVICE_GROUP:-$Service_User}"

# =========================
# 彩色输出
# =========================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# =========================
# 前置校验
# =========================
if [ "$(id -u)" -ne 0 ]; then
  err "需要 root 权限执行安装脚本（请使用 sudo bash install.sh）"
  exit 1
fi

if [ ! -f "${Server_Dir}/.env" ]; then
  err "未找到 .env 文件，请确认脚本所在目录：${Server_Dir}"
  exit 1
fi

# =========================
# 同步到安装目录（保持你原逻辑）
# =========================
mkdir -p "$Install_Dir"
if [ "$Server_Dir" != "$Install_Dir" ]; then
  info "同步项目文件到安装目录：${Install_Dir}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' "$Server_Dir/" "$Install_Dir/"
  else
    cp -a "$Server_Dir/." "$Install_Dir/"
  fi
fi

chmod +x "$Install_Dir"/*.sh 2>/dev/null || true
chmod +x "$Install_Dir"/scripts/* 2>/dev/null || true
chmod +x "$Install_Dir"/bin/* 2>/dev/null || true
chmod +x "$Install_Dir"/clashctl 2>/dev/null || true

# =========================
# 加载环境与依赖脚本
# =========================
# shellcheck disable=SC1090
source "$Install_Dir/.env"
# shellcheck disable=SC1090
source "$Install_Dir/scripts/get_cpu_arch.sh"
# shellcheck disable=SC1090
source "$Install_Dir/scripts/resolve_clash.sh"
# shellcheck disable=SC1090
source "$Install_Dir/scripts/port_utils.sh"

if [[ -z "${CpuArch:-}" ]]; then
  err "无法识别 CPU 架构"
  exit 1
fi
info "CPU architecture: ${CpuArch}"

# =========================
# 交互式填写订阅地址（仅在 CLASH_URL 为空时触发）
# - 若非 TTY（CI/管道）则跳过交互
# - 若用户回车跳过，则保持原行为：装完提示手动配置
# =========================
prompt_clash_url_if_empty() {
  # 兼容 .env 里可能是 CLASH_URL= 或 CLASH_URL=""
  local cur="${CLASH_URL:-}"
  cur="${cur%\"}"; cur="${cur#\"}"

  if [ -n "$cur" ]; then
    return 0
  fi

  # 非交互环境：不阻塞
  if [ ! -t 0 ]; then
    warn "CLASH_URL 为空且当前为非交互环境（stdin 非 TTY），将跳过输入引导。"
    return 0
  fi

  echo
  warn "未检测到订阅地址（CLASH_URL 为空）"
  echo "请粘贴你的 Clash 订阅地址（直接回车跳过，稍后手动编辑 .env）："
  read -r -p "Clash URL: " input_url

  if [ -z "$input_url" ]; then
    warn "已跳过填写订阅地址，安装完成后请手动编辑：${Install_Dir}/.env"
    return 0
  fi

  if ! echo "$input_url" | grep -Eq '^https?://'; then
    err "订阅地址格式不正确（必须以 http:// 或 https:// 开头）"
    exit 1
  fi

  # 写入 .env：优先替换已存在的 CLASH_URL= 行；若不存在则追加
  if grep -qE '^CLASH_URL=' "$Install_Dir/.env"; then
    # 用 | 做分隔符，避免 URL 里有 /
    sed -i "s|^CLASH_URL=.*|CLASH_URL=\"$input_url\"|g" "$Install_Dir/.env"
  else
    echo "CLASH_URL=\"$input_url\"" >> "$Install_Dir/.env"
  fi

  export CLASH_URL="$input_url"
  ok "已写入订阅地址到：${Install_Dir}/.env"
}

prompt_clash_url_if_empty

# =========================
# 端口冲突检测（保持你原逻辑）
# =========================
CLASH_HTTP_PORT=${CLASH_HTTP_PORT:-7890}
CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT:-7891}
CLASH_REDIR_PORT=${CLASH_REDIR_PORT:-7892}
EXTERNAL_CONTROLLER=${EXTERNAL_CONTROLLER:-127.0.0.1:9090}

parse_port() {
  local raw="$1"
  raw="${raw##*:}"
  echo "$raw"
}

Port_Conflicts=()
for port in "$CLASH_HTTP_PORT" "$CLASH_SOCKS_PORT" "$CLASH_REDIR_PORT" "$(parse_port "$EXTERNAL_CONTROLLER")"; do
  if [ "$port" = "auto" ] || [ -z "$port" ]; then
    continue
  fi
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    if is_port_in_use "$port"; then
      Port_Conflicts+=("$port")
    fi
  fi
done

if [ "${#Port_Conflicts[@]}" -ne 0 ]; then
  warn "检测到端口冲突: ${Port_Conflicts[*]}，运行时将自动分配可用端口"
fi

# =========================
# 创建运行用户/组
# =========================
if ! getent group "$Service_Group" >/dev/null 2>&1; then
  groupadd --system "$Service_Group"
fi

if ! id "$Service_User" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$Service_Group" "$Service_User"
fi

install -d -m 0755 "$Install_Dir/conf" "$Install_Dir/logs" "$Install_Dir/temp"
chown -R "$Service_User:$Service_Group" "$Install_Dir/conf" "$Install_Dir/logs" "$Install_Dir/temp"

# =========================
# Clash 内核就绪检查/下载
# =========================
if ! resolve_clash_bin "$Install_Dir" "$CpuArch" >/dev/null 2>&1; then
  err "Clash 内核未就绪，请检查下载配置或手动放置二进制"
  exit 1
fi

# =========================
# systemd 安装与启动
# =========================
Service_Enabled="unknown"
Service_Started="unknown"

if command -v systemctl >/dev/null 2>&1; then
  CLASH_SERVICE_USER="$Service_User" CLASH_SERVICE_GROUP="$Service_Group" "$Install_Dir/scripts/install_systemd.sh"

  if [ "${CLASH_ENABLE_SERVICE:-true}" = "true" ]; then
    systemctl enable "${Service_Name}.service" >/dev/null 2>&1 || true
  fi
  if [ "${CLASH_START_SERVICE:-true}" = "true" ]; then
    systemctl start "${Service_Name}.service" >/dev/null 2>&1 || true
  fi

  if systemctl is-enabled --quiet "${Service_Name}.service" 2>/dev/null; then
    Service_Enabled="enabled"
  else
    Service_Enabled="disabled"
  fi

  if systemctl is-active --quiet "${Service_Name}.service" 2>/dev/null; then
    Service_Started="active"
  else
    Service_Started="inactive"
  fi
else
  warn "未检测到 systemd，已跳过服务单元生成"
fi

# =========================
# 安装 clashctl 命令
# =========================
if [ -f "$Install_Dir/clashctl" ]; then
  install -m 0755 "$Install_Dir/clashctl" /usr/local/bin/clashctl
fi

# =========================
# 友好收尾输出（闭环）
# =========================
echo
ok "Clash for Linux 已安装至: ${Install_Dir}"
echo

echo -e "📦 安装目录：${Install_Dir}"
echo -e "👤 运行用户：${Service_User}:${Service_Group}"
echo -e "🔧 服务名称：${Service_Name}.service"

if command -v systemctl >/dev/null 2>&1; then
  echo -e "🧷 开机自启：${Service_Enabled}"
  echo -e "🟢 服务状态：${Service_Started}"
  echo
  echo -e "常用命令："
  echo -e "  sudo systemctl status ${Service_Name}.service"
  echo -e "  sudo systemctl restart ${Service_Name}.service"
fi

echo
# 面板地址与 secret（尽量从 .env 推导）
api_port="$(parse_port "${EXTERNAL_CONTROLLER}")"
api_host="${EXTERNAL_CONTROLLER%:*}"
# 默认只提示本机访问（更安全）
if [ -z "$api_host" ] || [ "$api_host" = "$EXTERNAL_CONTROLLER" ]; then
  api_host="127.0.0.1"
fi

# ---- Secret 展示（脱敏）----
CONF_DIR="${CLASH_INSTALL_DIR:-/opt/clash-for-linux}/conf"
CONF_FILE="$CONF_DIR/config.yaml"

# 读取 secret（如果 clash 还没生成 config，就先不显示）
SECRET_VAL=""
if [ -f "$CONF_FILE" ]; then
  SECRET_VAL="$(awk -F': *' '/^secret:/{print $2; exit}' "$CONF_FILE" | tr -d '"' | tr -d "'" )"
fi

if [ -n "$SECRET_VAL" ]; then
  # 脱敏显示：前4后4
  MASKED="${SECRET_VAL:0:4}****${SECRET_VAL: -4}"
  echo ""
  echo -e "🌐 Dashboard：http://${api_host}:${api_port}/ui"
  echo "🔐 Secret：${MASKED}"
  echo "   查看完整 Secret：sudo awk -F': *' '/^secret:/{print \$2; exit}' $CONF_FILE"
else
  echo ""
  echo -e "🌐 Dashboard：http://${api_host}:${api_port}/ui"
  echo "🔐 Secret：未读取到（服务首次启动后生成），可用以下命令查看："
  echo "   sudo awk -F': *' '/^secret:/{print \$2; exit}' $CONF_FILE"
fi

echo
if [ -n "${CLASH_URL:-}" ]; then
  ok "订阅地址已配置（CLASH_URL 已写入 .env）"
else
  warn "订阅地址未配置：请编辑 ${Install_Dir}/.env 设置 CLASH_URL"
fi

echo
echo -e "🧭 下一步（可选）："
echo -e "  source /etc/profile.d/clash-for-linux.sh"
echo -e "  proxy_on"
echo
sleep 1
if journalctl -u clash-for-linux.service -n 30 --no-pager | grep -q "Clash订阅地址不可访问"; then
  echo "[WARN] 服务启动失败：订阅不可用，请检查 CLASH_URL（可能过期/404）。"
fi
