#!/bin/bash

#################### 脚本初始化任务 ####################

# 获取脚本工作目录绝对路径
export Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# 加载.env变量文件
source $Server_Dir/.env

#################### 变量设置 ####################

Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"

# 将 CLASH_URL 变量的值赋给 URL 变量，并检查 CLASH_URL 是否为空
URL=${CLASH_URL:?Error: CLASH_URL variable is not set or empty}

# 获取 CLASH_SECRET 值，若未设置则尝试读取旧配置，否则生成随机数
Secret=${CLASH_SECRET:-}
if [ -z "$Secret" ] && [ -f "$Conf_Dir/config.yaml" ]; then
	Secret=$(awk -F': ' '/^secret:/{print $2; exit}' "$Conf_Dir/config.yaml")
fi
if [ -z "$Secret" ]; then
	Secret=$(openssl rand -hex 32)
fi

# 设置默认值
CLASH_HTTP_PORT=${CLASH_HTTP_PORT:-7890}
CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT:-7891}
CLASH_REDIR_PORT=${CLASH_REDIR_PORT:-7892}
CLASH_LISTEN_IP=${CLASH_LISTEN_IP:-0.0.0.0}
CLASH_ALLOW_LAN=${CLASH_ALLOW_LAN:-false}
EXTERNAL_CONTROLLER_ENABLED=${EXTERNAL_CONTROLLER_ENABLED:-true}
EXTERNAL_CONTROLLER=${EXTERNAL_CONTROLLER:-127.0.0.1:9090}
ALLOW_INSECURE_TLS=${ALLOW_INSECURE_TLS:-false}

#################### 函数定义 ####################

# 自定义action函数，实现通用action功能
success() {
	echo -en "\\033[60G[\\033[1;32m  OK  \\033[0;39m]\r"
	return 0
}

failure() {
	local rc=$?
	echo -en "\\033[60G[\\033[1;31mFAILED\\033[0;39m]\r"
	[ -x /bin/plymouth ] && /bin/plymouth --details
	return $rc
}

action() {
	local STRING rc

	STRING=$1
	echo -n "$STRING "
	shift
	"$@" && success $"$STRING" || failure $"$STRING"
	rc=$?
	echo
	return $rc
}

# 判断命令是否正常执行 函数
if_success() {
	local ReturnStatus=$3
	if [ $ReturnStatus -eq 0 ]; then
		action "$1" /bin/true
	else
		action "$2" /bin/false
		exit 1
	fi
}

#################### 任务执行 ####################

## 临时取消环境变量
unset http_proxy
unset https_proxy
unset no_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset NO_PROXY

## Clash 订阅地址检测及配置文件下载
echo -e '\n正在检测订阅地址...'
Text1="Clash订阅地址可访问！"
Text2="Clash订阅地址不可访问！"

# 构建检测 curl 命令，添加自定义请求头
CHECK_CMD=(curl -o /dev/null -L -sS --retry 5 -m 10 --connect-timeout 10 -w "%{http_code}")
if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
	CHECK_CMD+=(-k)
	echo -e "\033[33m[WARN] 已启用不安全的 TLS 下载（跳过证书校验）\033[0m"
fi
if [ -n "$CLASH_HEADERS" ]; then
	CHECK_CMD+=(-H "$CLASH_HEADERS")
fi
CHECK_CMD+=("$URL")

# 检查订阅地址
status_code=$("${CHECK_CMD[@]}")
echo "$status_code" | grep -E '^[23][0-9]{2}$' &>/dev/null
ReturnStatus=$?
if_success $Text1 $Text2 $ReturnStatus

# 拉取更新config.yml文件
echo -e '\n正在下载Clash配置文件...'
Text3="配置文件config.yaml下载成功！"
Text4="配置文件config.yaml下载失败，退出更新！"

# 构建 curl 命令，添加自定义请求头
CURL_CMD=(curl -L -sS --retry 5 -m 10 -o "$Temp_Dir/clash.yaml")
if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
	CURL_CMD+=(-k)
fi
if [ -n "$CLASH_HEADERS" ]; then
	CURL_CMD+=(-H "$CLASH_HEADERS")
fi
CURL_CMD+=("$URL")

# 尝试使用curl进行下载
"${CURL_CMD[@]}"
ReturnStatus=$?
if [ $ReturnStatus -ne 0 ]; then
	# 如果使用curl下载失败，尝试使用wget进行下载
	WGET_CMD=(wget -q -O "$Temp_Dir/clash.yaml")
	if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
		WGET_CMD+=(--no-check-certificate)
	fi
	if [ -n "$CLASH_HEADERS" ]; then
		WGET_CMD+=(--header="$CLASH_HEADERS")
	fi
	WGET_CMD+=("$URL")
	
	for i in {1..10}
	do
		"${WGET_CMD[@]}"
		ReturnStatus=$?
		if [ $ReturnStatus -eq 0 ]; then
			break
		else
			continue
		fi
	done
fi
if_success $Text3 $Text4 $ReturnStatus

# 重命名clash配置文件
\cp -a $Temp_Dir/clash.yaml $Temp_Dir/clash_config.yaml

## 判断订阅内容是否符合clash配置文件标准，尝试转换（需 subconverter 可执行文件支持）
if [ -x "$Server_Dir/tools/subconverter/subconverter" ]; then
	echo -e '\n判断订阅内容是否符合clash配置文件标准:'
	bash $Server_Dir/scripts/clash_profile_conversion.sh
	sleep 3
else
	echo -e "\033[33m[WARN] 未检测到可用的 subconverter，跳过订阅转换\033[0m"
fi

## Clash 配置文件重新格式化及配置
sed -n '/^proxies:/,$p' $Temp_Dir/clash_config.yaml > $Temp_Dir/proxy.txt

# 合并形成新的config.yaml，并替换配置占位符
cat $Temp_Dir/templete_config.yaml > $Temp_Dir/config.yaml
cat $Temp_Dir/proxy.txt >> $Temp_Dir/config.yaml

# 替换配置文件中的占位符为环境变量值
sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" $Temp_Dir/config.yaml
sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" $Temp_Dir/config.yaml
sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" $Temp_Dir/config.yaml
sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" $Temp_Dir/config.yaml
sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" $Temp_Dir/config.yaml

# 配置 external-controller
if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
	sed -i "s/EXTERNAL_CONTROLLER_PLACEHOLDER/${EXTERNAL_CONTROLLER}/g" $Temp_Dir/config.yaml
else
	# 如果禁用 external-controller，则注释掉该行
	sed -i "s/external-controller: 'EXTERNAL_CONTROLLER_PLACEHOLDER'/# external-controller: disabled/g" $Temp_Dir/config.yaml
fi

\cp $Temp_Dir/config.yaml $Conf_Dir/

# Configure Clash Dashboard
Work_Dir=$(cd $(dirname $0); pwd)
Dashboard_Dir="${Work_Dir}/dashboard/public"
if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
	sed -ri "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@g" $Conf_Dir/config.yaml
fi
sed -r -i '/^secret: /s@(secret: ).*@\1'${Secret}'@g' $Conf_Dir/config.yaml

echo -e "\n订阅更新完成，如需生效请执行: bash restart.sh\n"
