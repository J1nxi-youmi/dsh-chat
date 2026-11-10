# 给 flutter 现生成的 Windows 工程打补丁（CI 里跑）。
#
# 背景：just_audio_windows 0.2.3 的 C++ 走 C++/WinRT + /await 的 <experimental/coroutine>，
# 新版 MSVC（VS 18 / 14.51）把这条路直接判成错误 STL1011：
#   error C2338: static assertion failed: 'error STL1011: The /await compiler option,
#   <experimental/coroutine>, ... are deprecated by Microsoft and will be REMOVED SOON.'
# 微软给的临时开关就是 _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS。
#
# 把它加到 windows/CMakeLists.txt 里（目录级），会继承到 flutter/ 和插件子目录，
# 从而带进 just_audio_windows 的 vcxproj。
$ErrorActionPreference = 'Stop'

$define = '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'
$cmake = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/CMakeLists.txt'

if (-not (Test-Path -LiteralPath $cmake)) {
    throw "找不到 $cmake（先跑 flutter create --platforms=windows）"
}

$text = Get-Content -LiteralPath $cmake -Raw
if ($text -match [regex]::Escape($define)) {
    Write-Host "windows/CMakeLists.txt 已有 $define，跳过"
} else {
    $insert = "add_compile_definitions($define)"
    $patched = [regex]::Replace(
        $text,
        '(?m)^project\([^\r\n]*\)\r?\n',
        { param($m) $m.Value + $insert + "`r`n" },
        1
    )
    if ($patched -eq $text) {
        throw "windows/CMakeLists.txt 里没找到 project(...) 行，补丁没打上"
    }
    # 写回时统一 UTF-8 无 BOM：CMake 不认 BOM，PowerShell 5.1 的 Set-Content 会加。
    [System.IO.File]::WriteAllText($cmake, $patched, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已给 windows/CMakeLists.txt 加上 $define"
}

Write-Host '--- windows/CMakeLists.txt 前 10 行 ---'
Get-Content -LiteralPath $cmake -TotalCount 10 | ForEach-Object { "  | $_" }
