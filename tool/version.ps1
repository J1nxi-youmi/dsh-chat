# 版本号规则，和 tool/version.sh 一致。
param([Parameter(Mandatory=$true)][int]$Run)
$baseBuild = 45
$baseMinor = 3
$baseVersion = "0.3.0"
$seq = $Run - $baseBuild
if ($seq -le 0) { Write-Output $baseVersion; exit 0 }
$idx = $seq - 1
$minor = $baseMinor + [math]::Floor($idx / 10)
$patch = ($idx % 10) + 1
Write-Output ("0.{0}.{1:D2}" -f $minor, $patch)
