#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
version=2.3.8-snowy.6
build_number=203131
case "${1:-}" in
  '') target=android-arm; abi=armeabi-v7a ;;
  --local) target=android-arm64; abi=arm64-v8a ;;
  *) echo '用法：build-tv.sh [--local]' >&2; exit 2 ;;
esac
output="$here/Snowy-TV_${version}_${abi}.apk"

if ! command -v flutter >/dev/null && [[ -x /private/tmp/snowytv-build-01a1b8e6/flutter/bin/flutter ]]; then
  export PATH="/private/tmp/snowytv-build-01a1b8e6/flutter/bin:$PATH"
  export JAVA_HOME="/private/tmp/snowytv-build-01a1b8e6/jdk/Contents/Home"
  export ANDROID_HOME="/private/tmp/snowytv-build-01a1b8e6/android-sdk"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  export PUB_CACHE="/private/tmp/snowytv-build-01a1b8e6/pub-cache"
  export GRADLE_USER_HOME="/private/tmp/snowytv-build-01a1b8e6/gradle-cache"
fi

command -v flutter >/dev/null || { echo '请将 Flutter 3.47.6 加入 PATH。' >&2; exit 1; }

stage=$(mktemp -d "${TMPDIR:-/tmp}/snowy-tv.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
src="$here"
if [[ -d "$here/源码" ]]; then
  src="$here/源码"
fi

rsync -a --exclude .dart_tool --exclude .flutter-plugins-dependencies \
  --exclude build --exclude .gradle --exclude local.properties "$src/" "$stage/"

# Keep the local signing key between builds so adb can update the installed app.
export ANDROID_USER_HOME="$here/.signing"
mkdir -p "$ANDROID_USER_HOME"
chmod 700 "$ANDROID_USER_HOME"
cd "$stage"
flutter build apk --release --split-per-abi --target-platform "$target" \
  --build-name "$version" --build-number "$build_number"
cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "$output"
shasum -a 256 "$output"
