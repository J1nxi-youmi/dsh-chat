#!/usr/bin/env bash
# 在 CI 里给 flutter 生成的 AndroidManifest 补两样东西：
# 1) 录音 / 选文件的权限
# 2) 允许明文 HTTP（聊天服务常是 http://192.168.x.x:8792）
set -euo pipefail

MANIFEST=android/app/src/main/AndroidManifest.xml

if [ ! -f "$MANIFEST" ]; then
  echo "找不到 $MANIFEST" >&2
  exit 1
fi

if ! grep -q 'android.permission.RECORD_AUDIO' "$MANIFEST"; then
  # 插在 <manifest> 开标签之后
  perl -0pi -e 's#(<manifest[^>]*>)#$1\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />\n    <uses-permission android:name="android.permission.INTERNET" />#' "$MANIFEST"
fi

if ! grep -q 'usesCleartextTraffic' "$MANIFEST"; then
  perl -0pi -e 's#(<application\b)#$1 android:usesCleartextTraffic="true"#' "$MANIFEST"
fi

echo "--- AndroidManifest 关键行 ---"
grep -E 'RECORD_AUDIO|INTERNET|usesCleartextTraffic' "$MANIFEST"
