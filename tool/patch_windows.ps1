# 给 flutter 现生成的 Windows 工程打补丁（CI 里跑）。
#
# 做四件事：
#   1) CMakeLists 加 _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
#      （just_audio_windows 的 C++/WinRT 在新 MSVC 下报 STL1011）；
#   2) 窗口标题统一改成 Dshchat；
#   3) 应用图标换成仓库里的 tool/app_icon.ico；
#   4) 标题栏开暗色（DWMWA_USE_IMMERSIVE_DARK_MODE），跟 App 主题一致。
$ErrorActionPreference = 'Stop'

$define = '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'
$root = Split-Path -Parent $PSScriptRoot
$cmake = Join-Path $root 'windows/CMakeLists.txt'
$mainCpp = Join-Path $root 'windows/runner/main.cpp'

# ---------- 1) CMakeLists ----------
if (-not (Test-Path -LiteralPath $cmake)) {
    throw "找不到 $cmake（先跑 flutter create --platforms=windows）"
}
$text = [System.IO.File]::ReadAllText($cmake)
if ($text.Contains($define)) {
    Write-Host "CMakeLists 已有 $define，跳过"
} else {
    $insert = "add_compile_definitions($define)"
    $patched = [regex]::Replace($text, '(?m)^project\([^\r\n]*\)\r?\n', { param($m) $m.Value + $insert + "`r`n" }, 1)
    if ($patched -eq $text) { throw "CMakeLists 里没找到 project(...) 行" }
    [System.IO.File]::WriteAllText($cmake, $patched, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "CMakeLists 已加 $define"
}

# ---------- 2) 窗口标题 ----------
if (Test-Path -LiteralPath $mainCpp) {
    $mt = [System.IO.File]::ReadAllText($mainCpp)
    $patched = [regex]::Replace($mt, '(Create\(L")[^"]+(")', '$1Dshchat$2')
    if ($patched -ne $mt) {
        [System.IO.File]::WriteAllText($mainCpp, $patched, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "窗口标题已改为 Dshchat"
    }
}

# ---------- 3) 应用图标 ----------
$icoSrc = Join-Path $root 'tool/app_icon.ico'
$icoDst = Join-Path $root 'windows/runner/resources/app_icon.ico'
if ((Test-Path -LiteralPath $icoSrc) -and (Test-Path -LiteralPath (Split-Path -Parent $icoDst))) {
    Copy-Item -LiteralPath $icoSrc -Destination $icoDst -Force
    Write-Host "应用图标已替换为 tool/app_icon.ico"
}

# ---------- 4) 深色标题栏 ----------
if (Test-Path -LiteralPath $mainCpp) {
    $mt = [System.IO.File]::ReadAllText($mainCpp)
    $changed = $false
    if (-not $mt.Contains('dwmapi.h')) {
        $mt = $mt.Replace('#include <windows.h>', "#include <windows.h>`n#include <dwmapi.h>`n#pragma comment(lib, `"dwmapi.lib`")")
        $changed = $true
    }
    if (-not $mt.Contains('DWMWA_USE_IMMERSIVE_DARK_MODE')) {
        $dark = "`n  HWND hwnd = window.GetHandle();`n  BOOL darkTitle = TRUE;`n  DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &darkTitle, sizeof(darkTitle));"
        $mt = $mt.Replace('if (!window.Create(L"Dshchat", origin, size)) {', "if (!window.Create(L`"Dshchat`", origin, size)) {" + $dark)
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($mainCpp, $mt, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "标题栏已设为暗色（DWMWA_USE_IMMERSIVE_DARK_MODE）"
    }
}

Write-Host "--- Windows 补丁完成 ---"
