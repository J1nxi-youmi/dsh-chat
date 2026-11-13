#!/usr/bin/env bash
# 版本号规则（原有规则 + 10.10 特殊进位）：
#   base 0.3.0 -> 0.3.01 -> ... -> 0.3.10 -> 0.4.01 -> ...
#   ... -> 0.10.10 -> 1.01.01 -> 1.01.02 -> ... -> 1.10.10 -> 2.01.01
# 除 x.10.10 -> (x+1).01.01 外，仍然每 10 个 patch 进一个 minor。
# BASE_BUILD 那次构建对应 BASE_VERSION，之后每次构建 +1。
# 用法：bash tool/version.sh <run_number>
set -euo pipefail
RUN=${1:?need run number}
BASE_BUILD=45
BASE_MAJOR=0
BASE_MINOR=3
BASE_VERSION="0.3.0"
seq=$((RUN - BASE_BUILD))
if [ "$seq" -le 0 ]; then
  echo "$BASE_VERSION"
  exit 0
fi
idx=$((seq - 1))

# 当前 major 从 BASE_MINOR 开始，先跑完 3..10 这 8 个 minor。
first_cycle=$(( (10 - BASE_MINOR + 1) * 10 ))
if [ "$idx" -lt "$first_cycle" ]; then
  major=$BASE_MAJOR
  minor=$((BASE_MINOR + idx / 10))
  patch=$((idx % 10 + 1))
else
  # 之后每个 major 固定 10 个 minor，每个 minor 10 个 patch。
  after=$((idx - first_cycle))
  major=$((BASE_MAJOR + 1 + after / 100))
  within=$((after % 100))
  minor=$((1 + within / 10))
  patch=$((within % 10 + 1))
fi

if [ "$major" -eq 0 ]; then
  printf '0.%d.%02d\n' "$minor" "$patch"
else
  printf '%d.%02d.%02d\n' "$major" "$minor" "$patch"
fi
