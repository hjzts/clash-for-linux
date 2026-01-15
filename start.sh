#!/usr/bin/env bash
set -euo pipefail

############################################
# Clash for Linux - start.sh (Full Version)
# - systemd 模式下订阅失败/下载失败：不退出，使用 conf/config.yaml（必要时从 conf/fallback_config.yaml 拷贝）兜底启动
# - 非 systemd 模式：订阅失败/下载失败直接退出（保持手动执行的强约束）
############################################

# 加载系统函数库(Only for RHEL Linux)
[ -f /etc/init.d/functions ] && source /etc/init.d/functions

#################### 脚本初始化任务 ####################

# 获取脚本工作目录绝对路径
export Server_Dir
Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载.env变量文件
# shellcheck disable=SC1090
[ -f "$Server_Dir/.env" ] && source "$Server_Dir/.env"

# systemd 模式开关（必须在 set -u 下安全）
SYSTEMD_MODE="${SYSTEMD_MODE:-false}"

# 给二进制启动程序、脚本等添加可执行权限
chmod +x "$Server_Dir/bin/"* 2>/dev/null || true
chmod +x "$Server_Dir/scripts/"* 2>/dev/null || true
if [ -f "$Server_Dir/tools/subconverter/subconverter" ]; then
  chmod +x "$Server_Dir/tools/subconverter/subconverter" 2>/dev/null || true
fi

#################### 变量设置 ####################

Conf_Dir="$Server_Dir/conf"

# systemd + 非 root 运行（clash 用户）时，临时目录与日志目录必须可写
if [ "${SYSTEMD_MODE:-false}" = "true" ] && [ "$(id -u)" -ne 0 ]; then
  Temp_Dir="/tmp/clash-for-linux"
  Log_Dir="/tmp/clash-for-linux/logs"
else
  Temp_Dir="$Server_Dir/temp"
  Log_Dir="$Server_Dir/logs"
fi

mkdir -p "$Conf_Dir" "$Temp_Dir" "$Log_Dir" || {
  echo "[ERR] cannot create dirs: Conf_Dir=$Conf_Dir Temp_Dir=$Temp_Dir Log_Dir=$Log_Dir"
  exit 2
}

# 再做一次可写性检查，避免后面玄学 exit
touch "$Temp_Dir/.write_test" 2>/dev/null || { echo "[ERR] Temp_Dir not writable: $Temp_Dir"; exit 2; }
rm -f "$Temp_Dir/.write_test" 2>/dev/null || true

PID_FILE="${CLASH_PID_FILE:-$Temp_Dir/clash.pid}"

is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

if is_running; then
  echo -e "\n[OK] Clash 已在运行 (pid=$(cat "$PID_FILE"))，跳过重复启动\n"
  exit 0
fi

# 统一订阅变量
URL="${CLASH_URL:-}"

# 清理可能的 CRLF（Windows 写 .env 很常见）
URL="$(printf '%s' "$URL" | tr -d '\r')"

# 只有在“需要在线更新订阅”的模式下才强制要求 URL
if [ -z "$URL" ] && [ "${SYSTEMD_MODE:-false}" != "true" ]; then
  echo "[ERR] CLASH_URL 为空（未配置订阅地址）"
  exit 2
fi

# 获取 CLASH_SECRET 值：优先 .env；其次读取旧 config；占位符视为无效；最后生成随机值
Secret="${CLASH_SECRET:-}"

# 尝试从旧 config.yaml 读取（仅当 .env 未提供）
if [ -z "$Secret" ] && [ -f "$Conf_Dir/config.yaml" ]; then
  Secret="$(awk -F': *' '/^secret:/{gsub(/"/,"",$2); print $2; exit}' "$Conf_Dir/config.yaml" || true)"
fi

# 若读取到的是占位符（如 ${CLASH_SECRET}），视为无效
if [[ "$Secret" =~ ^\$\{.*\}$ ]]; then
  Secret=""
fi

# 兜底生成随机 secret
if [ -z "$Secret" ]; then
  if command -v openssl >/dev/null 2>&1; then
    Secret="$(openssl rand -hex 32)"
  else
    # 32 bytes -> 64 hex chars
    Secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi

# 强制写入 secret 到指定配置文件（存在则替换，不存在则追加）
force_write_secret() {
  local file="$1"
  [ -f "$file" ] || return 0

  if grep -qE '^[[:space:]]*secret:' "$file"; then
    # 替换整行 secret（无论原来是啥，包括 SECRET_PLACEHOLDER / "${CLASH_SECRET}"）
    sed -i -E "s|^[[:space:]]*secret:.*$|secret: ${Secret}|g" "$file"
  else
    # 没有 secret 行就追加到文件末尾
    printf "\nsecret: %s\n" "$Secret" >> "$file"
  fi
}

# 设置默认值
CLASH_HTTP_PORT="${CLASH_HTTP_PORT:-7890}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7891}"
CLASH_REDIR_PORT="${CLASH_REDIR_PORT:-7892}"
CLASH_LISTEN_IP="${CLASH_LISTEN_IP:-127.0.0.1}"
CLASH_ALLOW_LAN="${CLASH_ALLOW_LAN:-false}"

EXTERNAL_CONTROLLER_ENABLED="${EXTERNAL_CONTROLLER_ENABLED:-true}"
EXTERNAL_CONTROLLER="${EXTERNAL_CONTROLLER:-127.0.0.1:9090}"

ALLOW_INSECURE_TLS="${ALLOW_INSECURE_TLS:-false}"

# 端口与配置工具
# shellcheck disable=SC1090
source "$Server_Dir/scripts/port_utils.sh"
CLASH_HTTP_PORT="$(resolve_port_value "HTTP" "$CLASH_HTTP_PORT")"
CLASH_SOCKS_PORT="$(resolve_port_value "SOCKS" "$CLASH_SOCKS_PORT")"
CLASH_REDIR_PORT="$(resolve_port_value "REDIR" "$CLASH_REDIR_PORT")"
EXTERNAL_CONTROLLER="$(resolve_host_port "External Controller" "$EXTERNAL_CONTROLLER" "127.0.0.1")"

# shellcheck disable=SC1090
source "$Server_Dir/scripts/config_utils.sh"

#################### 函数定义 ####################

# 自定义action函数，实现通用action功能（兼容 journald；关键错误会额外 echo 到 stderr）
success() {
  echo -en "\033[60G[\033[1;32m OK \033[0;39m]\r"
  return 0
}

failure() {
  local rc=$?
  echo -en "\033[60G[\033[1;31mFAILED\033[0;39m]\r"
  [ -x /bin/plymouth ] && /bin/plymouth --details
  return "$rc"
}

action() {
  local STRING rc
  STRING=$1
  echo -n "$STRING "
  shift
  "$@" && success $"$STRING" || failure $"$STRING"
  rc=$?
  echo
  return "$rc"
}

# 判断命令是否正常执行（手动模式：失败退出；systemd 模式：由调用处决定）
if_success() {
  local ok_msg=$1
  local fail_msg=$2
  local rc=$3
  if [ "$rc" -eq 0 ]; then
    action "$ok_msg" /bin/true
  else
    action "$fail_msg" /bin/false
    exit 1
  fi
}

#################### 任务执行 ####################

## 获取CPU架构信息
# shellcheck disable=SC1090
source "$Server_Dir/scripts/get_cpu_arch.sh"

if [[ -z "${CpuArch:-}" ]]; then
  echo "[ERROR] Failed to obtain CPU architecture" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$Server_Dir/scripts/resolve_clash.sh"

## 临时取消环境变量
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY || true

########################################################
# systemd 兜底：如果没有可用订阅 URL，则确保有 config.yaml
########################################################
ensure_fallback_config() {
  # conf/config.yaml 为空或不存在，则从 fallback 拷贝
  if [ ! -s "$Conf_Dir/config.yaml" ]; then
    if [ -s "$Server_Dir/conf/fallback_config.yaml" ]; then
      cp -f "$Server_Dir/conf/fallback_config.yaml" "$Conf_Dir/config.yaml"
      echo -e "\033[33m[WARN]\033[0m 已复制 fallback_config.yaml -> conf/config.yaml（兜底）"
    else
      echo -e "\033[31m[ERROR]\033[0m 未找到可用的 conf/fallback_config.yaml，无法兜底启动" >&2
      exit 1
    fi
  fi
  # 强制写入真实 secret
  force_write_secret "$Conf_Dir/config.yaml"
}

SKIP_CONFIG_REBUILD=false

# systemd 模式下若 URL 为空：直接兜底启动
if [ "${SYSTEMD_MODE}" = "true" ] && [ -z "${URL:-}" ]; then
  echo -e "\033[33m[WARN]\033[0m SYSTEMD_MODE=true 且 CLASH_URL 为空，跳过订阅更新，使用本地兜底配置启动"
  ensure_fallback_config
  SKIP_CONFIG_REBUILD=true
fi

#################### Clash 订阅地址检测及配置文件下载 ####################
if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
  echo -e '\n正在检测订阅地址...'
  Text1="Clash订阅地址可访问！"
  Text2="Clash订阅地址不可访问！"

  CHECK_CMD=(curl -o /dev/null -L -sS --retry 5 -m 10 --connect-timeout 10 -w "%{http_code}")
  if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
    CHECK_CMD+=(-k)
    echo -e "\033[33m[WARN]\033[0m 已启用不安全的 TLS 下载（跳过证书校验）"
  fi
  if [ -n "${CLASH_HEADERS:-}" ]; then
    CHECK_CMD+=(-H "$CLASH_HEADERS")
  fi
  CHECK_CMD+=("$URL")

  # 不让 set -e 干扰获取状态码
  set +e
  status_code="$("${CHECK_CMD[@]}")"
  curl_rc=$?
  set -e

  # curl 本身失败，视为不可用
  if [ "$curl_rc" -ne 0 ]; then
    status_code=""
    ReturnStatus=1
  else
    echo "$status_code" | grep -E '^[23][0-9]{2}$' &>/dev/null
    ReturnStatus=$?
  fi

  if [ "$ReturnStatus" -eq 0 ]; then
    action "$Text1" /bin/true
  else
    # systemd 模式：不退出，尝试使用旧配置/兜底配置继续启动
    if [ "$SYSTEMD_MODE" = "true" ]; then
      action "$Text2（systemd 模式不退出，尝试使用旧配置/兜底配置）" /bin/false
      echo -e "\033[33m[WARN]\033[0m Subscribe check failed: http_code=${status_code:-unknown}, url=${URL}" >&2
      ensure_fallback_config
      SKIP_CONFIG_REBUILD=true
    else
      if_success "$Text1" "$Text2" "$ReturnStatus"
    fi
  fi
fi

#################### 下载订阅并生成 config.yaml（非兜底路径） ####################
if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
  echo -e '\n正在下载Clash配置文件...'
  Text3="配置文件clash.yaml下载成功！"
  Text4="配置文件clash.yaml下载失败！"

  CURL_CMD=(curl -L -sS --retry 5 -m 10 -o "$Temp_Dir/clash.yaml")
  if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
    CURL_CMD+=(-k)
  fi
  if [ -n "${CLASH_HEADERS:-}" ]; then
    CURL_CMD+=(-H "$CLASH_HEADERS")
  fi
  CURL_CMD+=("$URL")

  set +e
  "${CURL_CMD[@]}"
  ReturnStatus=$?
  set -e

  if [ "$ReturnStatus" -ne 0 ]; then
    WGET_CMD=(wget -q -O "$Temp_Dir/clash.yaml")
    if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
      WGET_CMD+=(--no-check-certificate)
    fi
    if [ -n "${CLASH_HEADERS:-}" ]; then
      WGET_CMD+=(--header="$CLASH_HEADERS")
    fi
    WGET_CMD+=("$URL")

    for _ in {1..10}; do
      set +e
      "${WGET_CMD[@]}"
      ReturnStatus=$?
      set -e
      if [ "$ReturnStatus" -eq 0 ]; then
        break
      fi
    done
  fi

  if [ "$ReturnStatus" -eq 0 ]; then
    action "$Text3" /bin/true
  else
    if [ "$SYSTEMD_MODE" = "true" ]; then
      action "$Text4（systemd 模式：下载失败，使用旧配置/兜底配置继续启动）" /bin/false
      echo -e "\033[33m[WARN]\033[0m Download failed, will fallback. url=${URL}" >&2
      ensure_fallback_config
      SKIP_CONFIG_REBUILD=true
    else
      if_success "$Text3" "$Text4（退出启动）" "$ReturnStatus"
    fi
  fi
fi

#################### 订阅转换/拼接（非兜底路径） ####################
if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
  # 运行期配置文件：默认用 Temp_Dir（systemd + clash 用户可写）
  CONFIG_FILE="$Temp_Dir/config.yaml"

  # 1) 重命名订阅文件
  \cp -a "$Temp_Dir/clash.yaml" "$Temp_Dir/clash_config.yaml"

  # 2) 判断订阅内容是否符合 clash 配置文件标准，尝试转换（需 subconverter）
  # shellcheck disable=SC1090
  source "$Server_Dir/scripts/resolve_subconverter.sh"

  if [ "${Subconverter_Ready:-false}" = "true" ]; then
    echo -e '\n判断订阅内容是否符合clash配置文件标准:'
    export SUBCONVERTER_BIN="$Subconverter_Bin"
    bash "$Server_Dir/scripts/clash_profile_conversion.sh"
    sleep 1
  else
    echo -e "\033[33m[WARN]\033[0m 未检测到可用的 subconverter，跳过订阅转换"
  fi

  # 3) 取出代理相关配置（从 proxies: 开始）
  sed -n '/^proxies:/,$p' "$Temp_Dir/clash_config.yaml" > "$Temp_Dir/proxy.txt"

  # 4) 合并形成新的 config，并替换配置占位符
  cat "$Temp_Dir/templete_config.yaml" > "$CONFIG_FILE"
  cat "$Temp_Dir/proxy.txt" >> "$CONFIG_FILE"

  sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" "$CONFIG_FILE"
  sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" "$CONFIG_FILE"
  sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" "$CONFIG_FILE"
  sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" "$CONFIG_FILE"
  sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" "$CONFIG_FILE"

  # 5) 配置 external-controller
  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    sed -i "s/EXTERNAL_CONTROLLER_PLACEHOLDER/${EXTERNAL_CONTROLLER}/g" "$CONFIG_FILE"
  else
    sed -i "s/external-controller: 'EXTERNAL_CONTROLLER_PLACEHOLDER'/# external-controller: disabled/g" "$CONFIG_FILE"
  fi

  apply_tun_config "$CONFIG_FILE"
  apply_mixin_config "$CONFIG_FILE" "$Server_Dir"

  # 6) 是否同步到 conf（root/非 systemd 时才做；systemd+非root跳过）
  if [ "${SYSTEMD_MODE:-false}" = "true" ] && [ "$(id -u)" -ne 0 ]; then
    echo "[WARN] systemd(non-root): skip copying config to $Conf_Dir"
  else
    \cp "$CONFIG_FILE" "$Conf_Dir/"
  fi

  # 7) Dashboard external-ui（systemd+非root：把 ui 放 Temp_Dir 下，避免写 conf）
  Work_Dir="$(cd "$(dirname "$0")" && pwd)"
  Dashboard_Src="${Work_Dir}/dashboard/public"

  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    if [ "${SYSTEMD_MODE:-false}" = "true" ] && [ "$(id -u)" -ne 0 ]; then
      # runtime ui path (writable)
      Dashboard_Link="$Temp_Dir/ui"
      if [ -d "$Dashboard_Src" ]; then
        ln -sfn "$Dashboard_Src" "$Dashboard_Link" 2>/dev/null || true
      fi
    else
      # conf ui path (root can manage)
      Dashboard_Link="${Conf_Dir}/ui"
      if [ -d "$Dashboard_Src" ]; then
        ln -sfn "$Dashboard_Src" "$Dashboard_Link" || true
      else
        echo -e "\033[33m[WARN]\033[0m Dashboard source not found: $Dashboard_Src (external-ui may not work)"
      fi
    fi

    # ensure external-ui points to Dashboard_Link
    if grep -qE '^[[:space:]]*external-ui:' "$CONFIG_FILE"; then
      sed -i -E "s|^[[:space:]]*external-ui:.*$|external-ui: ${Dashboard_Link}|g" "$CONFIG_FILE"
    else
      printf "\nexternal-ui: %s\n" "$Dashboard_Link" >> "$CONFIG_FILE"
    fi
  fi

  # 8) 写入 secret（写到 runtime config）
  force_write_secret "$CONFIG_FILE"

else
  # 兜底路径：尽量也写入 secret（conf/config.yaml 可写时）
  if grep -qE '^secret:\s*' "$Conf_Dir/config.yaml" 2>/dev/null; then
    force_write_secret "$Conf_Dir/config.yaml"
  else
    echo "secret: ${Secret}" >> "$Conf_Dir/config.yaml" || true
  fi
fi

#################### 启动Clash服务 ####################

# 选择运行期配置文件与工作目录
# - systemd + 非 root(通常 User=clash)：用 Temp_Dir 下的运行态配置，工作目录也用 Temp_Dir（可写）
# - 其他情况：用 Conf_Dir/config.yaml，工作目录用 Conf_Dir
if [ "${SYSTEMD_MODE:-false}" = "true" ] && [ "$(id -u)" -ne 0 ]; then
  CONFIG_FILE="${CONFIG_FILE:-$Temp_Dir/config.yaml}"
  RUNTIME_DIR="${Temp_Dir}"
else
  CONFIG_FILE="${CONFIG_FILE:-$Conf_Dir/config.yaml}"
  RUNTIME_DIR="${Conf_Dir}"
fi

# 启动前确保配置文件存在且非空
if [ ! -s "$CONFIG_FILE" ]; then
  echo -e "\033[31m[ERROR]\033[0m config 不存在或为空：$CONFIG_FILE，无法启动 Clash" >&2
  exit 2
fi

# 最终护栏：禁止未渲染的占位符进入运行态
if grep -q '\${' "$CONFIG_FILE"; then
  echo "[ERROR] config contains unresolved placeholders (\${...}): $CONFIG_FILE" >&2
  exit 2
fi

# 确保运行目录存在且可写（clash/mihomo 可能会写 cache/geo 数据）
mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
touch "$RUNTIME_DIR/.write_test" 2>/dev/null || {
  echo "[ERROR] runtime dir not writable: $RUNTIME_DIR (uid=$(id -u))" >&2
  exit 2
}
rm -f "$RUNTIME_DIR/.write_test" 2>/dev/null || true

echo -e '\n正在启动Clash服务...'
Text5="服务启动成功！"
Text6="服务启动失败！"

Clash_Bin="$(resolve_clash_bin "$Server_Dir" "$CpuArch")"
ReturnStatus=$?

if [ "$ReturnStatus" -eq 0 ]; then
  if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
    echo "[INFO] SYSTEMD_MODE=true，前台启动交给 systemd 监管"
    echo "[INFO] Using config: $CONFIG_FILE"
    echo "[INFO] Using runtime dir: $RUNTIME_DIR"
    # systemd 前台：让 systemd 直接跟踪 clash 进程
    exec "$Clash_Bin" -d "$RUNTIME_DIR" -f "$CONFIG_FILE"
  else
    echo "[INFO] 后台启动 (nohup)"
    echo "[INFO] Using config: $CONFIG_FILE"
    echo "[INFO] Using runtime dir: $RUNTIME_DIR"
    nohup "$Clash_Bin" -d "$RUNTIME_DIR" -f "$CONFIG_FILE" >>"$Log_Dir/clash.log" 2>&1 &
    PID=$!
    ReturnStatus=$?
    if [ "$ReturnStatus" -eq 0 ]; then
      echo "$PID" > "$PID_FILE"
    fi
  fi
fi

if_success "$Text5" "$Text6" "$ReturnStatus"

#################### 输出信息 ####################

echo ''
if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
  echo -e "Clash Dashboard 访问地址: http://${EXTERNAL_CONTROLLER}/ui"

  SHOW_SECRET="${CLASH_SHOW_SECRET:-false}"
  SHOW_SECRET_MASKED="${CLASH_SHOW_SECRET_MASKED:-true}"

  if [ "$SHOW_SECRET" = "true" ]; then
    echo -e "Secret: ${Secret}"
  elif [ "$SHOW_SECRET_MASKED" = "true" ]; then
    # 脱敏：前4后4
    masked="${Secret:0:4}****${Secret: -4}"
    echo -e "Secret: ${masked}  (set CLASH_SHOW_SECRET=true to show full)"
  else
    echo -e "Secret: 已生成（未显示）。查看：/opt/clash-for-linux/conf/config.yaml 或 .env"
  fi
else
  echo -e "External Controller (Dashboard) 已禁用"
fi
echo ''

#################### 写入代理环境变量文件 ####################

Env_File="${CLASH_ENV_FILE:-}"

if [ "$Env_File" = "off" ] || [ "$Env_File" = "disabled" ]; then
  echo -e "\033[33m[WARN]\033[0m 已关闭环境变量文件生成"
else
  if [ -z "$Env_File" ]; then
    if [ -w /etc/profile.d ]; then
      Env_File="/etc/profile.d/clash-for-linux.sh"
    else
      Env_File="$Temp_Dir/clash-for-linux.sh"
    fi
  fi

  if [ -f /etc/profile.d/clash.sh ]; then
    echo -e "\033[33m[WARN]\033[0m 检测到旧版环境变量文件 /etc/profile.d/clash.sh，建议确认是否需要清理"
  fi

  mkdir -p "$(dirname "$Env_File")"

  cat >"$Env_File"<<EOF
# 开启系统代理
function proxy_on() {
  export http_proxy=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export https_proxy=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export no_proxy=127.0.0.1,localhost
  export HTTP_PROXY=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export HTTPS_PROXY=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export NO_PROXY=127.0.0.1,localhost
  echo -e "\033[32m[√] 已开启代理\033[0m"
}

# 关闭系统代理
function proxy_off() {
  unset http_proxy
  unset https_proxy
  unset no_proxy
  unset HTTP_PROXY
  unset HTTPS_PROXY
  unset NO_PROXY
  echo -e "\033[31m[×] 已关闭代理\033[0m"
}
EOF

  echo -e "请执行以下命令加载环境变量: source ${Env_File}\n"
  echo -e "请执行以下命令开启系统代理: proxy_on\n"
  echo -e "若要临时关闭系统代理，请执行: proxy_off\n"
fi
