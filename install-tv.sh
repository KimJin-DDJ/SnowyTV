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
version=2.3.8-tv.1
filename="Kazumi-TV_${version}_armeabi-v7a.apk"
sha256=abad3552cc5839a35422a588bb6beed52402713617776ab7c48fa881f39a2e6b
adb=adb
if ! command -v adb >/dev/null; then
  adb="$root/platform-tools/adb"
  [[ -x "$adb" ]] || fail '找不到 adb。请安装 Android SDK Platform-Tools，或把 platform-tools 放到脚本旁边。'
fi

serial=${1:-}
if [[ $serial == *:* ]]; then
  "$adb" connect "$serial"
fi
if [[ -z $serial ]]; then
  serial=$("$adb" get-serialno) || fail '请先连接一台电视，或传入目标设备的地址或序列号。'
fi

state=$("$adb" -s "$serial" get-state) || fail '设备未连接或未授权。请检查 adb devices -l 和电视上的调试设置。'
[[ $state == device ]] || fail "设备状态为 ${state}。请先在电视上完成调试授权。"

features=$("$adb" -s "$serial" shell pm list features | tr -d '\r')
grep -Fxq 'feature:android.software.leanback' <<< "$features" || fail '目标设备未报告 Android TV 功能，已停止安装。'
abis=$("$adb" -s "$serial" shell getprop ro.product.cpu.abilist | tr -d '\r')
[[ ",$abis," == *,armeabi-v7a,* ]] || fail "目标设备未报告 armeabi-v7a 支持（${abis}），已停止安装。"

apk=${SNOWYTV_APK:-"$root/01 Chromecast 电视版/$filename"}
if [[ -z ${SNOWYTV_APK:-} && ! -f $apk ]]; then
  tmp_dir=$(mktemp -d)
  trap 'rm -rf -- "$tmp_dir"' EXIT
  apk="$tmp_dir/$filename"
  curl --fail --location --show-error --silent --retry 2 --output "$apk" \
    "https://github.com/LeoLee0812/Kazumi-TV/releases/download/$version/$filename"
fi
[[ -f $apk ]] || fail "找不到 APK：$apk"

digest=$(shasum -a 256 < "$apk")
[[ ${digest%% *} == "$sha256" ]] || fail 'APK 的 SHA-256 与发布记录不符，已停止安装。'

"$adb" -s "$serial" install -r "$apk"
printf '安装完成。请在电视首页的「你的应用」中打开 Kazumi TV。\n'
