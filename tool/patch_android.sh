#!/usr/bin/env bash
# 在 CI 里给 flutter 生成的 Android 工程补几样东西：
# 1) 录音 / 网络权限
# 2) 允许明文 HTTP（聊天服务常是 http://192.168.x.x:8792）
# 3) 主工程 compileSdk 提到 36
#
# 插件模块自己的 compileSdk 不归这里管：file_picker 已升到 13.x 联邦版，
# android_file_picker 用的是 flutter.compileSdkVersion（跟随 Flutter SDK），
# 不再硬编码 34，所以 ':file_picker:checkReleaseAarMetadata' 那个坑没了。
set -euo pipefail

MANIFEST=android/app/src/main/AndroidManifest.xml

if [ ! -f "$MANIFEST" ]; then
  echo "找不到 $MANIFEST" >&2
  exit 1
fi

if ! grep -q 'android.permission.RECORD_AUDIO' "$MANIFEST"; then
  perl -0pi -e 's#(<manifest[^>]*>)#$1\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />\n    <uses-permission android:name="android.permission.INTERNET" />#' "$MANIFEST"
fi

if ! grep -q 'usesCleartextTraffic' "$MANIFEST"; then
  perl -0pi -e 's#(<application\b)#$1 android:usesCleartextTraffic="true"#' "$MANIFEST"
fi

GRADLE=android/app/build.gradle.kts
[ -f "$GRADLE" ] || GRADLE=android/app/build.gradle

perl -0pi -e 's/compileSdk\s*=\s*flutter\.compileSdkVersion/compileSdk = 36/' "$GRADLE"
perl -0pi -e 's/compileSdkVersion\s+flutter\.compileSdkVersion/compileSdkVersion 36/' "$GRADLE"

echo "--- AndroidManifest 关键行 ---"
grep -E 'RECORD_AUDIO|INTERNET|usesCleartextTraffic' "$MANIFEST"
echo "--- compileSdk ---"
grep -nE 'compileSdk' "$GRADLE" || true
