#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '用法：bash install-tv.sh [电视 IP:端口或 adb 设备序列号]\n'
  exit 0
fi
[[ $# -le 1 && ${1:-} != -* ]] || fail '用法：bash install-tv.sh [电视 IP:端口或 adb 设备序列号]'

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
version=2.3.8-snowy.9
adb=adb
if ! command -v adb >/dev/null; then
  if [[ -x "/private/tmp/snowytv-build-01a1b8e6/sdk/platform-tools/adb" ]]; then
    adb="/private/tmp/snowytv-build-01a1b8e6/sdk/platform-tools/adb"
  elif [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
    adb="$HOME/Library/Android/sdk/platform-tools/adb"
  elif [[ -x "$root/platform-tools/adb" ]]; then
    adb="$root/platform-tools/adb"
  else
    fail '找不到 adb。请安装 Android SDK Platform-Tools。'
  fi
fi

serial=${1:-}
if [[ $serial == *:* ]]; then
  "$adb" connect "$serial" || true
fi
if [[ -z $serial ]]; then
  # 优先找在线的设备，排除 offline
  serial=$("$adb" devices | awk '$2=="device"{print $1; exit}')
  if [[ -z $serial ]]; then
    fail '未找到处于在线状态(device)的电视。请检查电视是否开启调试并确认授权，或传入设备地址（例如 bash install-tv.sh 192.168.1.236:41439）。'
  fi
fi

state=$("$adb" -s "$serial" get-state 2>/dev/null) || fail "设备 $serial 未连接或未授权。请检查电视上的调试提示。"
[[ $state == device ]] || fail "设备状态为 ${state}。请先在电视上完成调试授权。"

abis=$("$adb" -s "$serial" shell getprop ro.product.cpu.abilist | tr -d '\r')

target_abi="armeabi-v7a"
expected_sha256="86744b4df8477fcb4b3ad75b32d6619c22c91eed288f041d528e30fb23bcd76b"
if [[ ",$abis," == *,arm64-v8a,* ]]; then
  target_abi="arm64-v8a"
  expected_sha256="e66de7ad024e50ca02eab787daaa50fd7d870f5f1f2293994b293222d602502c"
fi

apk_filename="SnowyTV-v${version}-${target_abi}.apk"
apk=""

if [[ -n "${SNOWYTV_APK:-}" && -f "$SNOWYTV_APK" ]]; then
  apk="$SNOWYTV_APK"
elif [[ -f "$root/$apk_filename" ]]; then
  apk="$root/$apk_filename"
elif [[ -f "$root/04 Snowy TV 优化版/$apk_filename" ]]; then
  apk="$root/04 Snowy TV 优化版/$apk_filename"
else
  # 从 GitHub Releases 自动下载
  printf '本地未找到 %s，正在从 GitHub Releases 下载...\n' "$apk_filename"
  tmp_dir=$(mktemp -d)
  trap 'rm -rf -- "$tmp_dir"' EXIT
  apk="$tmp_dir/$apk_filename"
  curl --fail --location --show-error --progress-bar --retry 2 --output "$apk" \
    "https://github.com/KimJin-DDJ/SnowyTV/releases/download/v${version}/$apk_filename" || {
      fail "下载失败。请手动将 $apk_filename 放到仓库根目录，或使用 SNOWYTV_APK 指定路径。"
    }
fi

[[ -f $apk ]] || fail "找不到 APK：$apk"

digest=$(shasum -a 256 < "$apk")
if [[ -n "$expected_sha256" && ${digest%% *} != "$expected_sha256" ]]; then
  printf '警告: APK SHA-256 (%s) 与预设不完全一致，继续安装...\n' "${digest%% *}"
fi

# 如果电视上残留有旧版 github 官方包名 com.example.kazumi 或 com.predidit.kazumi，自动卸载清理
installed_packages=$("$adb" -s "$serial" shell pm list packages | tr -d '\r')
if grep -Fxq 'package:com.example.kazumi' <<< "$installed_packages"; then
  printf '检测到电视上已安装旧版 Kazumi TV (com.example.kazumi)，正在自动卸载清理...\n'
  "$adb" -s "$serial" uninstall com.example.kazumi || true
fi
if grep -Fxq 'package:com.predidit.kazumi' <<< "$installed_packages"; then
  printf '检测到电视上已安装官方 Kazumi (com.predidit.kazumi)，正在自动卸载清理...\n'
  "$adb" -s "$serial" uninstall com.predidit.kazumi || true
fi

printf '正在安装最新 Snowy TV (%s) 到 %s...\n' "$(basename "$apk")" "$serial"
"$adb" -s "$serial" install -r "$apk"

# 启动应用
"$adb" -s "$serial" shell am start -n com.snowytv.chromecast/com.example.kazumi.MainActivity >/dev/null 2>&1 || true

printf '\n======================================================\n'
printf '✅ 最新版 Snowy TV (%s) 安装完成！\n' "$version"
printf '旧版 Kazumi TV 已清理，电视已自动启动最新版 Snowy TV。\n'
printf '======================================================\n'
