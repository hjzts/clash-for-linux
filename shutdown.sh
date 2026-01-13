#!/bin/bash

# 关闭clash服务
Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
Temp_Dir="$Server_Dir/temp"
PID_FILE="$Temp_Dir/clash.pid"
if [ -f "$PID_FILE" ]; then
	PID=$(cat "$PID_FILE")
	if [ -n "$PID" ]; then
		kill "$PID"
		for i in {1..5}; do
			sleep 1
			if ! kill -0 "$PID" 2>/dev/null; then
				break
			fi
		done
		if kill -0 "$PID" 2>/dev/null; then
			kill -9 "$PID"
		fi
	fi
	rm -f "$PID_FILE"
else
	PIDS=$(pgrep -f "clash-linux-")
	if [ -n "$PIDS" ]; then
		kill $PIDS
		for i in {1..5}; do
			sleep 1
			if ! pgrep -f "clash-linux-" >/dev/null; then
				break
			fi
		done
		if pgrep -f "clash-linux-" >/dev/null; then
			kill -9 $PIDS
		fi
	fi
fi

# 清除环境变量
> /etc/profile.d/clash-for-linux.sh

echo -e "\n服务关闭成功，请执行以下命令关闭系统代理：proxy_off\n"
