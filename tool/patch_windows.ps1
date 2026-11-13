# 给 flutter 现生成的 Windows 工程打补丁（CI 里跑）。
#
# 做四件事：
#   1) CMakeLists 加 _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
#      （just_audio_windows 的 C++/WinRT 在新 MSVC 下报 STL1011）；
#   2) 窗口标题统一改成「青屿」；
#   3) 应用图标换成仓库里的 tool/app_icon.ico；
#   4) 标题栏使用浅色（DWMWA_USE_IMMERSIVE_DARK_MODE = FALSE），跟青屿主题一致。
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
    $patched = [regex]::Replace($mt, '(Create\(L")[^"]+(")', '$1\u9752\u5c7f$2')
    if ($patched -ne $mt) {
        [System.IO.File]::WriteAllText($mainCpp, $patched, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "窗口标题已改为 青屿"
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
    # 幂等：双保险已存在就跳过，避免重复累积。
    if (-not $mt.Contains('DwmSetWindowAttribute(hwnd, 20,')) {
        $dark = "`n  HWND hwnd = window.GetHandle();`n  BOOL darkTitle = FALSE;`n  DwmSetWindowAttribute(hwnd, 20, &darkTitle, sizeof(darkTitle));`n  DwmSetWindowAttribute(hwnd, 19, &darkTitle, sizeof(darkTitle));"
        $mt = $mt.Replace('if (!window.Create(L"\u9752\u5c7f", origin, size)) {', "if (!window.Create(L`"\u9752\u5c7f`", origin, size)) {" + $dark)
        [System.IO.File]::WriteAllText($mainCpp, $mt, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "浅色标题栏已写入（20/19 双保险）"
    } else {
        Write-Host "标题栏设置已存在，跳过"
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($mainCpp, $mt, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "标题栏已设为暗色（DWMWA_USE_IMMERSIVE_DARK_MODE）"
    }
}

Write-Host "--- Windows 补丁完成 ---"
