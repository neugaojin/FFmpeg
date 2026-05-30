# ============================================================
# FFmpeg Windows 动态链接库(DLL)编译脚本 (PowerShell)
# 支持 MSYS2/MinGW-w64 和 MSVC 两种工具链
# ============================================================
param(
    [ValidateSet("shared", "static")]
    [string]$BuildType = "shared",

    [ValidateSet("x86_64", "i686", "aarch64")]
    [string]$Arch = "x86_64",

    [string]$Prefix = "",

    [string]$Toolchain = "",

    [ValidateSet("yes", "no")]
    [string]$HwAccel = "yes",

    [ValidateSet("yes", "no")]
    [string]$NoVersionSuffix = "yes",

    [int]$Jobs = 0,

    [string]$ExtraCflags = "",

    [string]$ExtraLdflags = "",

    [switch]$CleanOnly,

    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"

# ============================================================
# 配置变量
# ============================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceDir = $ScriptDir

if (-not $Prefix) {
    $Prefix = Join-Path $ScriptDir "output"
}
$Prefix = [System.IO.Path]::GetFullPath($Prefix)

if ($Jobs -le 0) {
    $Jobs = [Environment]::ProcessorCount
}

$ConfigLog = Join-Path $ScriptDir "configure.log"
$BuildLog  = Join-Path $ScriptDir "build.log"

# ============================================================
# 日志函数
# ============================================================
function Write-Info    { Write-Host "[INFO]    $args" -ForegroundColor Cyan }
function Write-Warn    { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-ErrorMsg { Write-Host "[ERROR]   $args" -ForegroundColor Red }
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Step    { Write-Host "`n========================================" -ForegroundColor Gray; Write-Host "$args" -ForegroundColor Magenta; Write-Host "========================================" -ForegroundColor Gray }

# ============================================================
# 环境检测
# ============================================================
$Script:Msys2Root   = $null
$Script:Msys2Env    = $null
$Script:Msys2Bash   = $null

function Get-Msys2Bash {
    $msys2Paths = @(
        "C:\msys64\usr\bin\bash.exe",
        "C:\msys2\usr\bin\bash.exe",
        "D:\msys64\usr\bin\bash.exe",
        "D:\msys2\usr\bin\bash.exe",
        "E:\msys64\usr\bin\bash.exe",
        "E:\msys2\usr\bin\bash.exe"
    )

    foreach ($p in $msys2Paths) {
        if (Test-Path $p) {
            $Script:Msys2Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $p))
            $Script:Msys2Bash = $p
            return $p
        }
    }

    $pathBash = (Get-Command "bash.exe" -ErrorAction SilentlyContinue).Source
    if ($pathBash) {
        $dir = Split-Path -Parent $pathBash
        if ($dir -match "msys" -or $dir -match "mingw") {
            $Script:Msys2Root = Split-Path -Parent (Split-Path -Parent $dir)
            $Script:Msys2Bash = $pathBash
            return $pathBash
        }
    }

    return $null
}

function Detect-Msys2Subsystem {
    if (-not $Script:Msys2Root) { return $null }

    $subsystems = @(
        @{ Name = "UCRT64";  Dir = "ucrt64";  Desc = "UCRT64 (推荐 - 现代 Windows C 运行时)" },
        @{ Name = "MINGW64"; Dir = "mingw64"; Desc = "MINGW64 (传统 MSVCRT)" },
        @{ Name = "CLANG64"; Dir = "clang64"; Desc = "CLANG64 (LLVM/Clang 工具链)" }
    )

    foreach ($sub in $subsystems) {
        $subDir = Join-Path $Script:Msys2Root $sub.Dir
        $gccPath = Join-Path $subDir "bin\gcc.exe"
        if (Test-Path $gccPath) {
            Write-Info "检测到已安装的子系统: $($sub.Desc)"
            return $sub.Name
        }
    }

    Write-Warn "未检测到已安装编译器的子系统，将使用默认 MSYS 环境。"
    Write-Warn "请在 MSYS2 的 UCRT64 或 MINGW64 终端中安装编译工具:"
    Write-Warn "  pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make mingw-w64-ucrt-x86_64-pkg-config"
    return $null
}

function Invoke-Msys2Bash {
    param([string]$Command, [string]$MsystemOverride = $null)

    if (-not $Script:Msys2Bash) { Write-ErrorMsg "未找到 MSYS2 bash。"; exit 1 }

    $msystem = if ($MsystemOverride) { $MsystemOverride } else { $Script:Msys2Env }

    if ($msystem) {
        $env:MSYSTEM = $msystem
        $env:PATH = "$($Script:Msys2Root)\$($msystem.ToLower())\bin;$($Script:Msys2Root)\usr\bin;$env:PATH"
    }

    & $Script:Msys2Bash -lc $Command 2>&1
}

function Get-VisualStudioInfo {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    }

    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -property installationPath 2>$null
        if ($vsPath) {
            return @{
                Path = $vsPath
                VcVars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
            }
        }
    }
    return $null
}

# ============================================================
# 依赖检查
# ============================================================
function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-DependencyCheck {
    Write-Step "检查编译环境..."

    $bash = Get-Msys2Bash

    if ($bash) {
        Write-Info "检测到 MSYS2: $bash (根目录: $Script:Msys2Root)"

        $Script:Msys2Env = Detect-Msys2Subsystem

        if (-not $Script:Msys2Env) {
            Write-ErrorMsg "未检测到任何已安装编译器的 MSYS2 子系统 (UCRT64/MINGW64/CLANG64)。"
            Write-ErrorMsg ""
            Write-ErrorMsg "请启动 MSYS2 的 UCRT64 终端并安装编译工具:"
            Write-ErrorMsg "  → 启动: C:\\msys64\\ucrt64.exe"
            Write-ErrorMsg "  → 安装: pacman -S mingw-w64-ucrt-x86_64-gcc \\"
            Write-ErrorMsg "                       mingw-w64-ucrt-x86_64-make \\"
            Write-ErrorMsg "                       mingw-w64-ucrt-x86_64-pkg-config"
            Write-ErrorMsg ""
            Write-ErrorMsg "也可以使用 MINGW64 终端:"
            Write-ErrorMsg "  → 启动: C:\\msys64\\mingw64.exe"
            Write-ErrorMsg "  → 安装: pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-make mingw-w64-x86_64-pkg-config"
            exit 1
        }

        Write-Info "使用子系统: $Script:Msys2Env"

        $result = Invoke-Msys2Bash -Command @"
if command -v gcc &>/dev/null; then echo "GCC_OK"; else echo "GCC_MISSING"; fi
if command -v make &>/dev/null; then echo "MAKE_OK"; else echo "MAKE_MISSING"; fi
if command -v pkg-config &>/dev/null; then echo "PKGCONFIG_OK"; else echo "PKGCONFIG_MISSING"; fi
"@ -MsystemOverride $Script:Msys2Env

        $missing = @()
        if ($result -match "GCC_MISSING")   { $missing += "gcc" }
        if ($result -match "MAKE_MISSING")  { $missing += "make" }
        if ($result -match "PKGCONFIG_MISSING") { $missing += "pkg-config" }

        if ($missing.Count -gt 0) {
            Write-ErrorMsg "$($Script:Msys2Env) 子系统中缺少必要工具: $($missing -join ', ')"
            Write-ErrorMsg ""
            Write-ErrorMsg "请启动 MSYS2 $($Script:Msys2Env) 终端并运行:"
            Write-ErrorMsg "  pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make mingw-w64-ucrt-x86_64-pkg-config"
            Write-ErrorMsg ""
            Write-ErrorMsg "提示: 不能在 MSYS 终端中安装 $($Script:Msys2Env) 的工具，"
            Write-ErrorMsg "       必须用对应的终端快捷方式启动。"
            exit 1
        }

        Write-Success "MSYS2 / $($Script:Msys2Env) 工具链已就绪。"
        return "msys2"
    }

    $vsInfo = Get-VisualStudioInfo
    if ($vsInfo) {
        Write-Info "检测到 Visual Studio: $($vsInfo.Path)"
        Write-Warn "MSVC 编译需要通过 MSYS2 运行 configure，且需要安装 MSYS2。"
        Write-Warn "如果未安装 MSYS2，请先用 compile_win.sh 脚本构建。"
        Write-Warn ""
        Write-Warn "要使用 MSVC 工具链编译，请确保:"
        Write-Warn "  1. 已安装 MSYS2 (https://www.msys2.org/)"
        Write-Warn "  2. 在 MSYS2 中安装: pacman -S make pkg-config diffutils"
        Write-Warn "  3. 在 VS Developer Command Prompt 中运行此脚本"
        exit 1
    }

    Write-ErrorMsg "未检测到可用的编译环境！"
    Write-ErrorMsg ""
    Write-ErrorMsg "请安装以下任一编译环境:"
    Write-ErrorMsg "  1. MSYS2 + MinGW-w64: https://www.msys2.org/"
    Write-ErrorMsg "     安装后执行: pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-make mingw-w64-x86_64-pkg-config"
    Write-ErrorMsg ""
    Write-ErrorMsg "  2. Visual Studio 2022 + MSYS2 (用于运行 configure)"
    Write-ErrorMsg "     MSVC 路径请使用 compile_win.sh 脚本在 MSYS2 中运行"
    Write-ErrorMsg ""
    Write-ErrorMsg "也可直接使用 compile_win.sh 脚本在 MSYS2 终端中编译。"
    exit 1
}

# ============================================================
# 编译环境信息输出
# ============================================================
function Invoke-PrintEnvironment {
    Write-Step "编译环境信息"
    Write-Info "源码目录:     $SourceDir"
    Write-Info "构建类型:     $BuildType"
    Write-Info "目标架构:     $Arch"
    Write-Info "安装路径:     $Prefix"
    Write-Info "并行任务:     $Jobs"
    Write-Info "硬件加速:     $HwAccel"
    Write-Info "无版号DLL:    $NoVersionSuffix"
    if ($Toolchain) { Write-Info "工具链:       $Toolchain" }
    if ($ExtraCflags) { Write-Info "额外CFLAGS:   $ExtraCflags" }
    if ($ExtraLdflags) { Write-Info "额外LDFLAGS:   $ExtraLdflags" }
}

# ============================================================
# 转换 Windows 路径为 MSYS2 路径
# ============================================================
function ConvertTo-Msys2Path {
    param([string]$WinPath)
    $normalized = $WinPath -replace '\\', '/'
    if ($normalized -match '^([A-Za-z]):(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest  = $Matches[2]
        return "/$drive$rest"
    }
    return $normalized
}

# ============================================================
# 清理旧的构建产物
# ============================================================
function Invoke-CleanBuild {
    Write-Step "清理旧的构建产物..."
    $bash = Get-Msys2Bash
    if (-not $bash) { Write-ErrorMsg "需要 MSYS2 来运行清理。"; exit 1 }

    $msys2Src = ConvertTo-Msys2Path $SourceDir
    Invoke-Msys2Bash -Command "cd `"$msys2Src`" && if [ -f Makefile ]; then make distclean 2>/dev/null || true; fi && find . -name '*.o' -delete 2>/dev/null; find . -name '*.d' -delete 2>/dev/null; echo 'CLEAN_DONE'"
    Write-Success "清理完成。"

    if ($CleanOnly) {
        Write-Success "仅清理模式，退出。"
        exit 0
    }
}

# ============================================================
# 运行 configure
# ============================================================
function Invoke-Configure {
    Write-Step "配置 FFmpeg 编译选项..."
    $bash = Get-Msys2Bash
    if (-not $bash) { Write-ErrorMsg "需要 MSYS2 来运行 configure。"; exit 1 }

    $msys2Src    = ConvertTo-Msys2Path $SourceDir
    $msys2Prefix = ConvertTo-Msys2Path $Prefix

    $configureOpts = @(
        "--prefix=`"$msys2Prefix`"",
        "--target-os=mingw32",
        "--arch=$Arch",
        "--enable-gpl",
        "--enable-nonfree",
        "--enable-version3",
        "--enable-hardcoded-tables",
        "--enable-swscale",
        "--disable-debug",
        "--disable-doc",
        "--disable-ffplay",
        "--disable-sdl2",
        "--disable-programs"
    )

    if ($BuildType -eq "shared") {
        $configureOpts += "--enable-shared"
        $configureOpts += "--disable-static"
    } else {
        $configureOpts += "--disable-shared"
        $configureOpts += "--enable-static"
    }

    $configureOpts += "--enable-w32threads"

    if ($HwAccel -eq "yes") {
        $configureOpts += "--enable-dxva2"
        $configureOpts += "--enable-d3d11va"
    }

    if ($Toolchain) {
        $configureOpts += "--toolchain=$Toolchain"
    }

    $baseLdflags = "-static-libgcc -static-libstdc++"
    if ($ExtraLdflags) {
        $baseLdflags = "$baseLdflags $ExtraLdflags"
    }
    $configureOpts += "--extra-ldflags=`"$baseLdflags`""
    $configureOpts += "--extra-libs=`"-Wl,-Bstatic,-lwinpthread,-Wl,-Bdynamic`""

    if ($ExtraCflags) {
        $configureOpts += "--extra-cflags=`"$ExtraCflags`""
    }

    $configureLine = "./configure " + ($configureOpts -join " ")

    $scriptContent = @"
cd "$msys2Src"
echo "========================================"
echo "运行 configure..."
echo "========================================"
$configureLine 2>&1
exit \$?
"@

    $tempScript = Join-Path $env:TEMP "ffmpeg_configure_$([System.IO.Path]::GetRandomFileName()).sh"
    [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::ASCII)

    try {
        Invoke-Msys2Bash -Command "bash `"$(ConvertTo-Msys2Path $tempScript)`"" | Tee-Object -FilePath $ConfigLog
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "配置失败！请查看 $ConfigLog 了解详情。"
            exit 1
        }
    } finally {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    }

    Write-Success "配置完成。"

    if ($NoVersionSuffix -eq "yes") {
        Invoke-StripVersionSuffix
    }
    Invoke-StaticLinkExternalLibs
}

# ============================================================
# 去掉 DLL 版本号后缀
# ============================================================
function Invoke-StripVersionSuffix {
    Write-Info "去掉 DLL 文件名中的版本号后缀..."
    $configMak = Join-Path $SourceDir "ffbuild\config.mak"
    if (-not (Test-Path $configMak)) {
        Write-Warn "未找到 $configMak，无法去掉版本号。"
        return
    }

    $msys2Config = ConvertTo-Msys2Path $configMak
    Invoke-Msys2Bash -Command @"
sed -i 's/^SLIBNAME_WITH_VERSION=.*/SLIBNAME_WITH_VERSION=\$(SLIBNAME)/' "$msys2Config"
sed -i 's/^SLIBNAME_WITH_MAJOR=.*/SLIBNAME_WITH_MAJOR=\$(SLIBNAME)/' "$msys2Config"
sed -i 's/^SLIB_INSTALL_NAME=.*/SLIB_INSTALL_NAME=\$(SLIBNAME)/' "$msys2Config"
sed -i 's/^SLIB_INSTALL_LINKS=.*/SLIB_INSTALL_LINKS=/' "$msys2Config"
echo "DONE"
"@

    Write-Success "DLL 将生成为无版本号命名 (如 avcodec.dll)。"
}

# ============================================================
# 静态链接外部依赖库
# ============================================================
function Invoke-StaticLinkExternalLibs {
    $configMak = Join-Path $SourceDir "ffbuild\config.mak"
    if (-not (Test-Path $configMak)) {
        Write-Warn "未找到 $configMak"
        return
    }

    Write-Info "将外部依赖库修改为静态链接..."
    $msys2Config = ConvertTo-Msys2Path $configMak
    Invoke-Msys2Bash -Command @"
sed -i -E 's/( |=)-lz\\b/\\1-Wl,-Bstatic -lz -Wl,-Bdynamic/g' "$msys2Config"
sed -i -E 's/( |=)-liconv\\b/\\1-Wl,-Bstatic -liconv -Wl,-Bdynamic/g' "$msys2Config"
sed -i -E 's/( |=)-lcharset\\b/\\1-Wl,-Bstatic -lcharset -Wl,-Bdynamic/g' "$msys2Config"
echo "DONE"
"@
    Write-Success "zlib、iconv、charset 已设为静态链接。"
}

# ============================================================
# 编译
# ============================================================
function Invoke-CompileBuild {
    Write-Step "编译 FFmpeg (使用 $Jobs 个并行任务)..."
    $bash = Get-Msys2Bash
    if (-not $bash) { Write-ErrorMsg "需要 MSYS2 来运行编译。"; exit 1 }

    $msys2Src = ConvertTo-Msys2Path $SourceDir

    $scriptContent = @"
cd "$msys2Src"
echo "========================================"
echo "开始多线程编译 (jobs: $Jobs)..."
echo "========================================"
make -j$Jobs 2>&1
exit \$?
"@

    $tempScript = Join-Path $env:TEMP "ffmpeg_build_$([System.IO.Path]::GetRandomFileName()).sh"
    [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::ASCII)

    try {
        Invoke-Msys2Bash -Command "bash `"$(ConvertTo-Msys2Path $tempScript)`"" | Tee-Object -FilePath $BuildLog
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Warn "多线程编译失败 (退出码: $exitCode)，尝试单线程编译以排查问题..."

            $singleScript = @"
cd "$msys2Src"
echo "========================================"
echo "单线程编译..."
echo "========================================"
make -j1 2>&1
exit \$?
"@
            $singleTemp = Join-Path $env:TEMP "ffmpeg_build_single_$([System.IO.Path]::GetRandomFileName()).sh"
            [System.IO.File]::WriteAllText($singleTemp, $singleScript, [System.Text.Encoding]::ASCII)
            try {
                Invoke-Msys2Bash -Command "bash `"$(ConvertTo-Msys2Path $singleTemp)`"" | Tee-Object -FilePath $BuildLog -Append
                if ($LASTEXITCODE -ne 0) {
                    Write-ErrorMsg "编译失败！请查看 $BuildLog 了解详情。"
                    exit 1
                }
            } finally {
                Remove-Item $singleTemp -Force -ErrorAction SilentlyContinue
            }
            Write-Success "单线程编译完成。"
            return
        }
    } finally {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    }

    Write-Success "编译完成。"
}

# ============================================================
# 安装
# ============================================================
function Invoke-InstallBuild {
    if ($SkipInstall) {
        Write-Warn "已通过 -SkipInstall 跳过安装步骤。"
        return
    }

    Write-Step "安装 FFmpeg 到: $Prefix"
    $bash = Get-Msys2Bash
    if (-not $bash) { Write-ErrorMsg "需要 MSYS2 来运行安装。"; exit 1 }

    $msys2Src    = ConvertTo-Msys2Path $SourceDir
    $msys2Prefix = ConvertTo-Msys2Path $Prefix

    $scriptContent = @"
cd "$msys2Src"
mkdir -p "$msys2Prefix"
make install 2>&1
exit \$?
"@

    $tempScript = Join-Path $env:TEMP "ffmpeg_install_$([System.IO.Path]::GetRandomFileName()).sh"
    [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::ASCII)

    try {
        Invoke-Msys2Bash -Command "bash `"$(ConvertTo-Msys2Path $tempScript)`""
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "安装失败！"
            exit 1
        }
    } finally {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    }

    Write-Success "安装完成。"
}

# ============================================================
# 产物摘要
# ============================================================
function Invoke-PrintSummary {
    Write-Host ""
    Write-Success "FFmpeg Windows 编译成功！"
    Write-Host ""

    Write-Info "输出目录: $Prefix"

    $binDir  = Join-Path $Prefix "bin"
    $incDir  = Join-Path $Prefix "include"
    $libDir  = Join-Path $Prefix "lib"

    if (Test-Path $binDir)  { Write-Info "├── bin/        # DLL 文件及可执行文件" }
    if (Test-Path $incDir)  { Write-Info "├── include/    # 头文件" }
    if (Test-Path $libDir)  { Write-Info "└── lib/        # 导入库 (.dll.a / .lib)" }

    Write-Host ""

    if ($BuildType -eq "shared" -and (Test-Path $binDir)) {
        $dllFiles = Get-ChildItem -Path $binDir -Filter "*.dll" -ErrorAction SilentlyContinue
        if ($dllFiles.Count -gt 0) {
            Write-Info "共生成 $($dllFiles.Count) 个 DLL 文件:"
            foreach ($dll in ($dllFiles | Sort-Object Name)) {
                $sizeKB = [math]::Round($dll.Length / 1KB, 1)
                Write-Host "        $($dll.Name)  ($($sizeKB) KB)" -ForegroundColor Gray
            }
        }
    }

    if (Test-Path $libDir) {
        $libFiles = Get-ChildItem -Path $libDir -Filter "*.dll.a" -ErrorAction SilentlyContinue
        if ($libFiles.Count -gt 0) {
            Write-Info "共生成 $($libFiles.Count) 个导入库文件 (.dll.a)"
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Gray

    Write-Info "使用说明:"
    Write-Info "  1. 将 $binDir 添加到系统 PATH 环境变量"
    Write-Info "  2. 链接时需要 $libDir 中的导入库文件"
    Write-Info "  3. 头文件位于 $incDir"
    Write-Host ""
}

# ============================================================
# 主流程
# ============================================================
function Main {
    Write-Host "========================================" -ForegroundColor Gray
    Write-Host "FFmpeg Windows 动态链接库(DLL)编译脚本" -ForegroundColor White
    Write-Host "运行环境: PowerShell (调用 MSYS2/MinGW-w64)" -ForegroundColor White
    Write-Host "目标平台: Windows ($Arch)" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Gray

    $envType = Invoke-DependencyCheck
    Invoke-PrintEnvironment
    Invoke-CleanBuild
    Invoke-Configure
    Invoke-CompileBuild
    Invoke-InstallBuild
    Invoke-PrintSummary
}

Main