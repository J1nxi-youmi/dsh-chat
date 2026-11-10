#!/usr/bin/env bash
# 在 CI 里给 flutter 生成的 Android 工程补几样东西：
# 1) 录音 / 网络权限
# 2) 允许明文 HTTP（聊天服务常是 http://192.168.x.x:8792）
# 3) compileSdk 提到 36（file_picker 等插件要求的）
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

# Kotlin DSL: compileSdk = flutter.compileSdkVersion
perl -0pi -e 's/compileSdk\s*=\s*flutter\.compileSdkVersion/compileSdk = 36/' "$GRADLE"
# Groovy DSL: compileSdkVersion flutter.compileSdkVersion
perl -0pi -e 's/compileSdkVersion\s+flutter\.compileSdkVersion/compileSdkVersion 36/' "$GRADLE"

# 插件模块（file_picker 等）自带 compileSdk 34，会在 checkReleaseAarMetadata 里失败。
# 在根工程里把所有子工程的 compileSdk 统一抬到 36。
ROOT_GRADLE=android/build.gradle.kts
if [ -f "$ROOT_GRADLE" ]; then
  if ! grep -q 'ci-compile-sdk-patch' "$ROOT_GRADLE"; then
    cat >> "$ROOT_GRADLE" <<'KTS'

// ci-compile-sdk-patch: 插件模块也抬到 36
subprojects {
    afterEvaluate {
        val androidExtension = extensions.findByName("android")
        if (androidExtension is com.android.build.gradle.BaseExtension) {
            androidExtension.compileSdkVersion(36)
        }
    }
}
KTS
  fi
else
  ROOT_GRADLE=android/build.gradle
  if [ -f "$ROOT_GRADLE" ] && ! grep -q 'ci-compile-sdk-patch' "$ROOT_GRADLE"; then
    cat >> "$ROOT_GRADLE" <<'GRV'

// ci-compile-sdk-patch: 插件模块也抬到 36
subprojects {
    afterEvaluate { project ->
        if (project.hasProperty('android')) {
            project.android.compileSdkVersion 36
        }
    }
}
GRV
  fi
fi

echo "--- compileSdk ---"
grep -nE 'compileSdk' "$GRADLE" || true
grep -nE 'subprojects' "$ROOT_GRADLE" || true
