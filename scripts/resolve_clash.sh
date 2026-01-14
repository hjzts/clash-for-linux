#!/bin/bash

resolve_clash_arch() {
	local raw_arch="$1"
	case "$raw_arch" in
		x86_64|amd64)
			echo "linux-amd64"
			;;
		aarch64|arm64)
			echo "linux-arm64"
			;;
		armv7*|armv7l)
			echo "linux-armv7"
			;;
		*)
			echo "linux-${raw_arch}"
			;;
	esac
}

download_clash_bin() {
	local server_dir="$1"
	local detected_arch="$2"
	local resolved_arch
	local download_url
	local download_target
	local archive_file

	resolved_arch=$(resolve_clash_arch "$detected_arch")
	if [ -z "$resolved_arch" ]; then
		echo -e "\033[33m[WARN] 无法识别 CPU 架构，跳过 Clash 内核自动下载\033[0m"
		return 1
	fi

	if [ "${CLASH_AUTO_DOWNLOAD:-auto}" = "false" ]; then
		return 1
	fi

	download_url="${CLASH_DOWNLOAD_URL_TEMPLATE:-https://github.com/Dreamacro/clash/releases/latest/download/clash-{arch}.gz}"
	if [ -z "$download_url" ]; then
		echo -e "\033[33m[WARN] 未设置 CLASH_DOWNLOAD_URL_TEMPLATE，跳过 Clash 内核自动下载\033[0m"
		return 1
	fi

	download_url="${download_url//\{arch\}/${resolved_arch}}"
	download_target="${server_dir}/bin/clash-${resolved_arch}"
	archive_file="${server_dir}/temp/clash-${resolved_arch}.download"

	mkdir -p "${server_dir}/bin" "${server_dir}/temp"

	if command -v curl >/dev/null 2>&1; then
		curl -L -sS -o "${archive_file}" "${download_url}"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "${archive_file}" "${download_url}"
	else
		echo -e "\033[33m[WARN] 未找到 curl 或 wget，无法自动下载 Clash 内核\033[0m"
		return 1
	fi

	if [ -f "${archive_file}" ]; then
		if gzip -t "${archive_file}" >/dev/null 2>&1; then
			gzip -dc "${archive_file}" >"${download_target}"
		else
			mv "${archive_file}" "${download_target}"
		fi
		chmod +x "${download_target}"
		echo "${download_target}"
		return 0
	fi

	echo -e "\033[33m[WARN] Clash 内核自动下载失败\033[0m"
	return 1
}

resolve_clash_bin() {
	local server_dir="$1"
	local detected_arch="$2"
	local resolved_arch
	local candidates=()
	local candidate
	local downloaded_bin

	if [ -n "${CLASH_BIN:-}" ]; then
		if [ -x "$CLASH_BIN" ]; then
			echo "$CLASH_BIN"
			return 0
		fi
		echo -e "\033[31m[ERROR] CLASH_BIN 指定的文件不可执行: $CLASH_BIN\033[0m"
		return 1
	fi

	resolved_arch=$(resolve_clash_arch "$detected_arch")
	if [ -n "$resolved_arch" ]; then
		candidates+=("${server_dir}/bin/clash-${resolved_arch}")
	fi
	candidates+=(
		"${server_dir}/bin/clash-${detected_arch}"
		"${server_dir}/bin/clash"
	)

	for candidate in "${candidates[@]}"; do
		if [ -x "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done

	if downloaded_bin=$(download_clash_bin "$server_dir" "$detected_arch"); then
		echo "$downloaded_bin"
		return 0
	fi

	echo -e "\033[31m\n[ERROR] 未找到可用的 Clash 二进制。\033[0m"
	echo -e "请将对应架构的二进制放入: $server_dir/bin/"
	echo -e "可用命名示例: clash-${resolved_arch} 或 clash-${detected_arch}"
	echo -e "或通过 CLASH_BIN 指定自定义路径。"
	return 1
}
