#requires -Version 5.1
param(
    [ValidateSet("x64")]
    [string]$Arch = "x64",

    [string]$Prefix = "",

    [string]$VsDevCmd = "",

    [string]$Bash = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-VsDevCmd {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath) {
            return (Resolve-Path -LiteralPath $ExplicitPath).Path
        }
        throw "未找到指定的 VsDevCmd.bat: $ExplicitPath"
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $installPath = & $vswhere `
            -latest `
            -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath

        if ($installPath) {
            $candidate = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    $fallbacks = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat"
    )

    foreach ($candidate in $fallbacks) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "未找到 Visual Studio Build Tools。请安装 VS Build Tools 2022，并勾选 C++ build tools。"
}

function Import-VsBuildEnvironment {
    param(
        [string]$VsDevCmdPath,
        [string]$TargetArch
    )

    $cmd = 'call "' + $VsDevCmdPath + '" -arch=' + $TargetArch + ' -host_arch=' + $TargetArch + ' >nul && set'
    $envDump = & cmd.exe /d /s /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "初始化 Visual Studio Build Tools 环境失败。"
    }

    foreach ($line in $envDump) {
        if ($line -match "^([^=]+)=(.*)$") {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        }
    }
}

function Find-MsysBash {
    param([string]$ExplicitPath)

    $candidates = @()
    if ($ExplicitPath) {
        $candidates += $ExplicitPath
    }
    if ($env:MSYS2_BASH) {
        $candidates += $env:MSYS2_BASH
    }
    $candidates += "C:\msys64\usr\bin\bash.exe"

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $fromPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    throw "未找到 MSYS2 bash。请安装 MSYS2，并确保 bash.exe 在 PATH 中，或通过 -Bash 指定路径。"
}

function Assert-MsysTool {
    param(
        [string]$BashPath,
        [string]$ToolName,
        [string]$InstallHint
    )

    $checkCommand = 'command -v ' + $ToolName + ' >/dev/null 2>&1'
    & $BashPath -lc $checkCommand
    if ($LASTEXITCODE -ne 0) {
        throw "MSYS2 环境中未找到 $ToolName。$InstallHint"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Prefix) {
    $Prefix = Join-Path $scriptDir "build\windows\$Arch"
}

$vsDevCmdPath = Find-VsDevCmd -ExplicitPath $VsDevCmd
$bashPath = Find-MsysBash -ExplicitPath $Bash

Write-Host "========================================"
Write-Host "开始编译 FFmpeg for Windows ($Arch)"
Write-Host "VS_DEV_CMD: $vsDevCmdPath"
Write-Host "MSYS_BASH:  $bashPath"
Write-Host "PREFIX:     $Prefix"
Write-Host "========================================"

Import-VsBuildEnvironment -VsDevCmdPath $vsDevCmdPath -TargetArch $Arch

Assert-MsysTool -BashPath $bashPath -ToolName "cygpath" -InstallHint "请确认使用的是 MSYS2 bash。"
Assert-MsysTool -BashPath $bashPath -ToolName "make" -InstallHint "可在 MSYS2 中执行: pacman -S make"
Assert-MsysTool -BashPath $bashPath -ToolName "nasm" -InstallHint "可在 MSYS2 中执行: pacman -S nasm"

$env:SRC_DIR_WIN = $scriptDir
$env:PREFIX_WIN = $Prefix
$env:CORES = [Environment]::ProcessorCount.ToString()

$buildScript = @'
set -e

SRC_DIR="$(cygpath -u "$SRC_DIR_WIN")"
PREFIX_DIR="$(cygpath -u "$PREFIX_WIN")"

cd "$SRC_DIR"
export PKG_CONFIG_PATH=""

make distclean >/dev/null 2>&1 || true

./configure \
  --prefix="$PREFIX_DIR" \
  --toolchain=msvc \
  --target-os=win64 \
  --arch=x86_64 \
  \
  --enable-shared \
  --disable-static \
  \
  --enable-gpl \
  --enable-nonfree \
  --enable-pthreads \
  \
  --enable-version3 \
  --enable-hardcoded-tables \
  --enable-swscale \
  \
  --disable-debug \
  --disable-doc \
  \
  --disable-ffplay \
  --disable-sdl2 \
  --disable-libxcb \
  --disable-xlib \
  \
  --extra-cflags="-MD -O2" \
  --extra-ldflags=""

make -j"${CORES:-4}" || make -j1
make install
'@

$tempBuildScript = Join-Path ([System.IO.Path]::GetTempPath()) ("ffmpeg_build_windows_{0}.sh" -f ([Guid]::NewGuid().ToString("N")))
Set-Content -LiteralPath $tempBuildScript -Value $buildScript -Encoding ASCII

try {
    $env:BUILD_SCRIPT_WIN = $tempBuildScript
    & $bashPath -lc 'bash "$(cygpath -u "$BUILD_SCRIPT_WIN")"'
} finally {
    Remove-Item -LiteralPath $tempBuildScript -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\BUILD_SCRIPT_WIN -ErrorAction SilentlyContinue
}

if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg Windows 编译失败。"
}

Write-Host "========================================"
Write-Host "编译完成！输出产物位于: $Prefix"
Write-Host "  bin\     -> ffmpeg.exe / ffprobe.exe / *.dll"
Write-Host "  lib\     -> MSVC import libs (*.lib)"
Write-Host "  include\ -> 头文件"
Write-Host "========================================"
