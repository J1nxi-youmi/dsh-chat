# 版本号规则，和 tool/version.sh 一致：
#   0.10.10 -> 1.01.01 -> ... -> 1.10.10 -> 2.01.01
param([Parameter(Mandatory=$true)][int]$Run)
$baseBuild = 45
$baseMajor = 0
$baseMinor = 3
$baseVersion = "0.3.0"
$seq = $Run - $baseBuild
if ($seq -le 0) { Write-Output $baseVersion; exit 0 }
$idx = $seq - 1

$firstCycle = (10 - $baseMinor + 1) * 10
if ($idx -lt $firstCycle) {
  $major = [int]$baseMajor
  $minor = [int]($baseMinor + [math]::Floor($idx / 10))
  $patch = [int](($idx % 10) + 1)
} else {
  $after = $idx - $firstCycle
  $major = [int]($baseMajor + 1 + [math]::Floor($after / 100))
  $within = $after % 100
  $minor = [int](1 + [math]::Floor($within / 10))
  $patch = [int](($within % 10) + 1)
}

if ($major -eq 0) {
  Write-Output ("0.{0}.{1:D2}" -f $minor, $patch)
} else {
  Write-Output ("{0}.{1:D2}.{2:D2}" -f $major, $minor, $patch)
}
