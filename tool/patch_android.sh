#!/usr/bin/env bash
# 在 CI 里给 flutter 生成的 Android 工程打补丁：
# 1) 录音 / 网络 / 通知 / 前台服务 权限
# 2) 允许明文 HTTP（聊天服务常是 http://192.168.x.x:8792）
# 3) 主工程 compileSdk 提到 36
# 4) 前台服务（保活）+ 系统通知：把 tool/android/*.kt 放进工程并声明 service
#
# 插件模块自己的 compileSdk 不归这里管：file_picker 已升到 13.x 联邦版。
set -euo pipefail

MANIFEST=android/app/src/main/AndroidManifest.xml

if [ ! -f "$MANIFEST" ]; then
  echo "找不到 $MANIFEST" >&2
  exit 1
fi

# --- 权限 ---
if ! grep -q 'android.permission.RECORD_AUDIO' "$MANIFEST"; then
  perl -0pi -e 's#(<manifest[^>]*>)#$1\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />\n    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING" />#' "$MANIFEST"
else
  # 老清单可能已经有 RECORD_AUDIO，只补通知 / 前台服务这几条。
  for perm in POST_NOTIFICATIONS FOREGROUND_SERVICE FOREGROUND_SERVICE_REMOTE_MESSAGING; do
    if ! grep -q "android.permission.$perm" "$MANIFEST"; then
      perl -0pi -e "s#(<uses-permission android:name=\"android.permission.RECORD_AUDIO\" />)#\$1\n    <uses-permission android:name=\"android.permission.$perm\" />#" "$MANIFEST"
    fi
  done
fi

# --- 明文 HTTP ---
if ! grep -q 'usesCleartextTraffic' "$MANIFEST"; then
  perl -0pi -e 's#(<application\b)#$1 android:usesCleartextTraffic="true"#' "$MANIFEST"
fi

# --- 前台服务声明 ---
if ! grep -q 'ChatService' "$MANIFEST"; then
  perl -0pi -e 's#(<application\b[^>]*>)#$1\n        <service android:name=".ChatService" android:exported="false" android:foregroundServiceType="remoteMessaging" />#' "$MANIFEST"
fi

# --- compileSdk ---
GRADLE=android/app/build.gradle.kts
[ -f "$GRADLE" ] || GRADLE=android/app/build.gradle

perl -0pi -e 's/compileSdk\s*=\s*flutter\.compileSdkVersion/compileSdk = 36/' "$GRADLE"
perl -0pi -e 's/compileSdkVersion\s+flutter\.compileSdkVersion/compileSdkVersion 36/' "$GRADLE"

# --- 关掉 release lint（lintVital）---
# JDK 21 + 新 AGP 对插件模块（url_launcher_android 等）的 lint 分析有
# NoSuchMethodError: List.removeLast() 的已知 bug，release 构建会被它卡死。
# release 检查交给 flutter analyze，这里直接跳过 lintVital。
if [ "${GRADLE##*.}" = "kts" ]; then
  perl -0pi -e 's#(android \{)#$1\n    lint { checkReleaseBuilds = false }#' "$GRADLE"
else
  perl -0pi -e 's#(android \{)#$1\n    lint {\n        checkReleaseBuilds false\n    }#' "$GRADLE"
fi

# --- 原生源码：MainActivity / ChatService / Notifications ---
PKG=$(grep -oE 'namespace[[:space:]]*=[[:space:]]*"[^"]+"' "$GRADLE" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
PKG=${PKG:-com.example.dsh_chat}
KT_DIR="android/app/src/main/kotlin/$(echo "$PKG" | tr '.' '/')"
mkdir -p "$KT_DIR"
for file in MainActivity ChatService Notifications; do
  sed "s/__PKG__/$PKG/g" "tool/android/$file.kt" > "$KT_DIR/$file.kt"
  echo "写入 $KT_DIR/$file.kt（package $PKG）"
done

# --- 固定签名 ---
# CI 每次都是全新环境，debug keystore 每次都不一样 —— 签名一变就装不上覆盖更新。
# 这里把仓库里的固定 keystore 拷进去，release 包都用它签。
cp tool/android/dsh-chat.jks android/app/dsh-chat.jks
if grep -q 'dsh-chat.jks' "$GRADLE"; then
  echo "签名已配置过"
elif [ "${GRADLE##*.}" = "kts" ]; then
  perl -0pi -e 's#(\n\s*buildTypes\s*\{)#\n    signingConfigs {\n        create("release") {\n            storeFile = file("dsh-chat.jks")\n            storePassword = "dshchat2026"\n            keyAlias = "dsh-chat"\n            keyPassword = "dshchat2026"\n        }\n    }\n$1#' "$GRADLE"
  perl -0pi -e 's#signingConfig = signingConfigs\.getByName\("debug"\)#signingConfig = signingConfigs.getByName("release")#' "$GRADLE"
  echo "已配置 release 签名（dsh-chat.jks）"
else
  echo "⚠️ 不是 build.gradle.kts，签名补丁没打" >&2
fi

echo "--- AndroidManifest 关键行 ---"
grep -E 'RECORD_AUDIO|INTERNET|POST_NOTIFICATIONS|FOREGROUND_SERVICE|usesCleartextTraffic|ChatService' "$MANIFEST"
echo "--- compileSdk ---"
grep -nE 'compileSdk' "$GRADLE" || true
