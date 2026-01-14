#!/bin/bash

set -euo pipefail

Server_Dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
Install_Dir="${CLASH_INSTALL_DIR:-/opt/clash-for-linux}"
Service_Name="clash-for-linux"
Service_User="${CLASH_SERVICE_USER:-clash}"
Service_Group="${CLASH_SERVICE_GROUP:-$Service_User}"

if [ "$(id -u)" -ne 0 ]; then
	echo -e "\033[31m[ERROR] 需要 root 权限执行安装脚本\033[0m"
	exit 1
fi

if [ ! -f "${Server_Dir}/.env" ]; then
	echo -e "\033[31m[ERROR] 未找到 .env 文件，请确认脚本所在目录\033[0m"
	exit 1
fi

mkdir -p "$Install_Dir"
if [ "$Server_Dir" != "$Install_Dir" ]; then
	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete --exclude '.git' "$Server_Dir/" "$Install_Dir/"
	else
		cp -a "$Server_Dir/." "$Install_Dir/"
	fi
fi

chmod +x "$Install_Dir"/*.sh 2>/dev/null || true
chmod +x "$Install_Dir"/scripts/* 2>/dev/null || true
chmod +x "$Install_Dir"/bin/* 2>/dev/null || true

source "$Install_Dir/.env"
source "$Install_Dir/scripts/get_cpu_arch.sh"
source "$Install_Dir/scripts/resolve_clash.sh"

if [[ -z "${CpuArch:-}" ]]; then
	echo -e "\033[31m[ERROR] 无法识别 CPU 架构\033[0m"
	exit 1
fi

CLASH_HTTP_PORT=${CLASH_HTTP_PORT:-7890}
CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT:-7891}
CLASH_REDIR_PORT=${CLASH_REDIR_PORT:-7892}
EXTERNAL_CONTROLLER=${EXTERNAL_CONTROLLER:-127.0.0.1:9090}

parse_port() {
	local raw="$1"
	raw="${raw##*:}"
	echo "$raw"
}

is_port_in_use() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -lnt | awk '{print $4}' | grep -E "(:|\.)${port}$" >/dev/null 2>&1
	elif command -v netstat >/dev/null 2>&1; then
		netstat -lnt | awk '{print $4}' | grep -E "(:|\.)${port}$" >/dev/null 2>&1
	elif command -v lsof >/dev/null 2>&1; then
		lsof -iTCP -sTCP:LISTEN -P -n | awk '{print $9}' | grep -E "(:|\.)${port}$" >/dev/null 2>&1
	else
		echo -e "\033[33m[WARN] 未找到端口检测工具，跳过端口冲突检测\033[0m"
		return 1
	fi
}

Port_Conflicts=()
for port in "$CLASH_HTTP_PORT" "$CLASH_SOCKS_PORT" "$CLASH_REDIR_PORT" "$(parse_port "$EXTERNAL_CONTROLLER")"; do
	if [[ "$port" =~ ^[0-9]+$ ]]; then
		if is_port_in_use "$port"; then
			Port_Conflicts+=("$port")
		fi
	fi
done

if [ "${#Port_Conflicts[@]}" -ne 0 ]; then
	echo -e "\033[31m[ERROR] 检测到端口冲突: ${Port_Conflicts[*]}\033[0m"
	echo -e "请修改 .env 中的端口设置后重新安装。"
	exit 1
fi

if ! getent group "$Service_Group" >/dev/null 2>&1; then
	groupadd --system "$Service_Group"
fi

if ! id "$Service_User" >/dev/null 2>&1; then
	useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$Service_Group" "$Service_User"
fi

install -d -m 0755 "$Install_Dir/conf" "$Install_Dir/logs" "$Install_Dir/temp"
chown -R "$Service_User:$Service_Group" "$Install_Dir/conf" "$Install_Dir/logs" "$Install_Dir/temp"

if ! resolve_clash_bin "$Install_Dir" "$CpuArch" >/dev/null 2>&1; then
	echo -e "\033[31m[ERROR] Clash 内核未就绪，请检查下载配置或手动放置二进制\033[0m"
	exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
	CLASH_SERVICE_USER="$Service_User" CLASH_SERVICE_GROUP="$Service_Group" "$Install_Dir/scripts/install_systemd.sh"
	if [ "${CLASH_ENABLE_SERVICE:-true}" = "true" ]; then
		systemctl enable "${Service_Name}.service" >/dev/null 2>&1 || true
	fi
	if [ "${CLASH_START_SERVICE:-true}" = "true" ]; then
		systemctl start "${Service_Name}.service" >/dev/null 2>&1 || true
	fi
else
	echo -e "\033[33m[WARN] 未检测到 systemd，已跳过服务单元生成\033[0m"
fi

echo -e "\033[32m[OK] Clash for Linux 已安装至: ${Install_Dir}\033[0m"
echo -e "请编辑 ${Install_Dir}/.env 配置订阅地址后启动服务。"
