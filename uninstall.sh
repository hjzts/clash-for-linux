#!/bin/bash

set -euo pipefail

Install_Dir="${CLASH_INSTALL_DIR:-/opt/clash-for-linux}"
Service_Name="clash-for-linux"

if [ "$(id -u)" -ne 0 ]; then
	echo -e "\033[31m[ERROR] 需要 root 权限执行卸载脚本\033[0m"
	exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
	systemctl stop "${Service_Name}.service" >/dev/null 2>&1 || true
	systemctl disable "${Service_Name}.service" >/dev/null 2>&1 || true
	if [ -f "/etc/systemd/system/${Service_Name}.service" ]; then
		rm -f "/etc/systemd/system/${Service_Name}.service"
		systemctl daemon-reload
	fi
fi

if [ -f "/etc/default/${Service_Name}" ]; then
	rm -f "/etc/default/${Service_Name}"
fi

if [ -f "/etc/profile.d/clash-for-linux.sh" ]; then
	rm -f "/etc/profile.d/clash-for-linux.sh"
fi

if [ -d "$Install_Dir" ]; then
	rm -rf "$Install_Dir"
	echo -e "\033[32m[OK] 已移除安装目录: ${Install_Dir}\033[0m"
else
	echo -e "\033[33m[WARN] 未找到安装目录: ${Install_Dir}\033[0m"
fi

