#!/usr/bin/env bash
# 版本号规则（十进制、每 10 个 patch 进一位）：
#   0.3.00 -> 0.3.01 -> ... -> 0.3.10 -> 0.4.01 -> ...
# BASE_BUILD 那次构建对应 BASE_VERSION，之后每次构建 +1。
# 用法：bash tool/version.sh <run_number>
set -euo pipefail
RUN=${1:?need run number}
BASE_BUILD=45
BASE_MINOR=3
BASE_VERSION="0.3.0"
seq=$((RUN - BASE_BUILD))
if [ "$seq" -le 0 ]; then
  echo "$BASE_VERSION"
  exit 0
fi
idx=$((seq - 1))
minor=$((BASE_MINOR + idx / 10))
patch=$((idx % 10 + 1))
printf '0.%d.%02d\n' "$minor" "$patch"
