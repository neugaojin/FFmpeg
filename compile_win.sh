#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# FFmpeg Windows 动态链接库(DLL)编译脚本
# 运行环境: MSYS2 / MinGW-w64
# ============================================================

# ---------- 可配置变量 (可通过环境变量覆盖) ----------
BUILD_TYPE="${BUILD_TYPE:-shared}"
ARCH="${ARCH:-x86_64}"
PREFIX="${PREFIX:-/e/work/projects/FFmpeg/windows}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
ENABLE_HWACCEL="${ENABLE_HWACCEL:-yes}"
NO_VERSION_SUFFIX="${NO_VERSION_SUFFIX:-yes}"
CFLAGS_EXTRA="${CFLAGS_EXTRA:-}"
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:-}"

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- 日志函数 ----------
log_info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# ---------- 分隔线 ----------
print_separator() {
    echo "========================================"
}

# ---------- 错误退出处理 ----------
on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "脚本在第 ${line_no} 行发生错误，退出码: ${exit_code}"
    log_error "请检查上方的编译日志以获取详细错误信息。"
    exit $exit_code
}

trap 'on_error ${LINENO}' ERR

# ---------- MSYS2 子系统检测 ----------
detect_msys2_env() {
    local msystem="${MSYSTEM:-}"

    if [ -z "$msystem" ]; then
        msystem="MSYS"
    fi

    case "$msystem" in
        MINGW64) echo "MINGW64" ;;
        MINGW32) echo "MINGW32" ;;
        UCRT64)  echo "UCRT64"  ;;
        CLANG64) echo "CLANG64" ;;
        CLANG32) echo "CLANG32" ;;
        MSYS)    echo "MSYS"    ;;
        *)       echo "UNKNOWN" ;;
    esac
}

# ---------- 获取当前环境的包前缀 ----------
get_pkg_prefix() {
    case "$MSYS2_ENV" in
        MINGW64) echo "mingw-w64-x86_64"     ;;
        MINGW32) echo "mingw-w64-i686"       ;;
        UCRT64)  echo "mingw-w64-ucrt-x86_64";;
        CLANG64) echo "mingw-w64-clang-x86_64";;
        CLANG32) echo "mingw-w64-clang-i686" ;;
        *)       echo ""                     ;;
    esac
}

# ---------- 依赖检查 ----------
check_dependencies() {
    print_separator
    log_info "检查编译依赖..."

    MSYS2_ENV=$(detect_msys2_env)
    log_info "当前 MSYS2 子系统: ${MSYS2_ENV}"

    if [ "$MSYS2_ENV" = "MSYS" ] || [ "$MSYS2_ENV" = "UNKNOWN" ]; then
        log_error "当前运行在 MSYS 环境中，该环境不包含 MinGW 编译工具链。"
        log_error ""
        log_error "请关闭当前终端，改用以下 MSYS2 快捷方式启动:"
        log_error "  → UCRT64 (推荐):  C:\\msys64\\ucrt64.exe"
        log_error "  → MINGW64:        C:\\msys64\\mingw64.exe"
        log_error ""
        log_error "启动后在该终端中安装工具:"
        log_error "  pacman -S mingw-w64-ucrt-x86_64-gcc \\"
        log_error "            mingw-w64-ucrt-x86_64-make \\"
        log_error "            mingw-w64-ucrt-x86_64-pkg-config"
        exit 1
    fi

    local missing=()
    local optional_missing=()

    for cmd in gcc g++ make pkg-config; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    for cmd in nasm yasm; do
        if ! command -v "$cmd" &>/dev/null; then
            optional_missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        local pkg_prefix
        pkg_prefix=$(get_pkg_prefix)
        log_error "缺少必要的依赖工具: ${missing[*]}"
        log_error ""
        log_error "请在当前终端 (${MSYS2_ENV}) 中运行以下命令安装:"
        log_error "  pacman -S ${pkg_prefix}-gcc \\"
        log_error "            ${pkg_prefix}-make \\"
        log_error "            ${pkg_prefix}-pkg-config"
        exit 1
    fi

    if [ ${#optional_missing[@]} -gt 0 ]; then
        log_warn "缺少可选的依赖工具: ${optional_missing[*]}"
        log_warn "某些汇编优化可能不可用，建议安装:"
        local pkg_prefix
        pkg_prefix=$(get_pkg_prefix)
        log_warn "  pacman -S nasm"
    fi

    log_success "所有必要依赖工具已就绪 (${MSYS2_ENV})。"
}

# ---------- 环境信息输出 ----------
print_environment() {
    print_separator
    log_info "编译环境信息:"
    log_info "  操作系统: $(uname -s)"
    log_info "  构建类型: ${BUILD_TYPE}"
    log_info "  目标架构: ${ARCH}"
    log_info "  安装路径: ${PREFIX}"
    log_info "  并行任务: ${JOBS}"
    log_info "  硬件加速: ${ENABLE_HWACCEL}"
    log_info "  无版号DLL: ${NO_VERSION_SUFFIX}"
    if command -v gcc &>/dev/null; then
        log_info "  GCC 版本: $(gcc --version 2>/dev/null | head -1 || echo '未知')"
    fi
    if command -v make &>/dev/null; then
        log_info "  Make 版本: $(make --version 2>/dev/null | head -1 || echo '未知')"
    fi
    print_separator
}

# ---------- 清理旧的构建产物 ----------
clean_build() {
    log_info "清理旧的构建产物..."
    if [ -f "Makefile" ]; then
        if ! make distclean 2>/dev/null; then
            log_warn "make distclean 失败，尝试手动清理..."
            rm -f config.h config.mak config.log 2>/dev/null || true
        fi
    fi
    find . -name "*.o" -delete 2>/dev/null || true
    find . -name "*.d" -delete 2>/dev/null || true
    log_success "清理完成。"
}

# ---------- 去掉 DLL 版本号后缀 ----------
strip_version_suffix() {
    local config_mak="ffbuild/config.mak"
    if [ ! -f "$config_mak" ]; then
        log_warn "未找到 ${config_mak}，无法去掉版本号。"
        return
    fi

    log_info "去掉 DLL 文件名中的版本号后缀..."
    sed -i 's/^SLIBNAME_WITH_VERSION=.*/SLIBNAME_WITH_VERSION=$(SLIBNAME)/' "$config_mak"
    sed -i 's/^SLIBNAME_WITH_MAJOR=.*/SLIBNAME_WITH_MAJOR=$(SLIBNAME)/'    "$config_mak"
    sed -i 's/^SLIB_INSTALL_NAME=.*/SLIB_INSTALL_NAME=$(SLIBNAME)/'          "$config_mak"
    sed -i 's/^SLIB_INSTALL_LINKS=.*/SLIB_INSTALL_LINKS=/'                   "$config_mak"
    log_success "DLL 将生成为无版本号命名 (如 avcodec.dll)。"
}

# ---------- 静态链接外部依赖库 ----------
static_link_external_libs() {
    local config_mak="ffbuild/config.mak"
    if [ ! -f "$config_mak" ]; then
        log_warn "未找到 ${config_mak}"
        return
    fi

    log_info "将外部依赖库修改为静态链接..."
    sed -i -E 's/( |=)-lz\b/\1-Wl,-Bstatic -lz -Wl,-Bdynamic/g'           "$config_mak"
    sed -i -E 's/( |=)-liconv\b/\1-Wl,-Bstatic -liconv -Wl,-Bdynamic/g'   "$config_mak"
    sed -i -E 's/( |=)-lcharset\b/\1-Wl,-Bstatic -lcharset -Wl,-Bdynamic/g' "$config_mak"
    log_success "zlib、iconv、charset 已设为静态链接。"
}

# ---------- 配置编译选项 ----------
configure_build() {
    print_separator
    log_info "开始配置 FFmpeg..."

    if [ ! -f "./configure" ]; then
        log_error "未找到 ./configure 脚本，请确保当前目录为 FFmpeg 源码根目录。"
        exit 1
    fi

    local configure_opts=(
        "--prefix=${PREFIX}"
        "--target-os=mingw32"
        "--arch=${ARCH}"

        "--enable-gpl"
        "--enable-nonfree"
        "--enable-version3"
        "--enable-hardcoded-tables"
        "--enable-swscale"

        "--disable-debug"
        "--disable-doc"
        "--disable-ffplay"
        "--disable-sdl2"
        "--disable-programs"
    )

    if [ "${BUILD_TYPE}" = "shared" ]; then
        configure_opts+=(
            "--enable-shared"
            "--disable-static"
        )
    else
        configure_opts+=(
            "--disable-shared"
            "--enable-static"
        )
    fi

    configure_opts+=("--enable-w32threads")

    if [ "${ENABLE_HWACCEL}" = "yes" ]; then
        configure_opts+=(
            "--enable-dxva2"
            "--enable-d3d11va"
        )
    fi

    local extra_ldflags="-static-libgcc -static-libstdc++"
    if [ -n "${LDFLAGS_EXTRA}" ]; then
        extra_ldflags="${extra_ldflags} ${LDFLAGS_EXTRA}"
    fi
    configure_opts+=("--extra-ldflags=${extra_ldflags}")
    configure_opts+=("--extra-libs=-Wl,-Bstatic -lwinpthread -Wl,-Bdynamic")

    if [ -n "${CFLAGS_EXTRA}" ]; then
        configure_opts+=("--extra-cflags=${CFLAGS_EXTRA}")
    fi

    log_info "运行: ./configure ${configure_opts[*]}"

    if ./configure "${configure_opts[@]}" 2>&1 | tee configure.log; then
        log_success "配置完成。"
    else
        log_error "配置失败！请查看 configure.log 了解详情。"
        exit 1
    fi

    if [ "${NO_VERSION_SUFFIX}" = "yes" ]; then
        strip_version_suffix
    fi
    static_link_external_libs
}

# ---------- 编译 ----------
compile_build() {
    print_separator
    log_info "开始编译 FFmpeg (使用 ${JOBS} 个并行任务)..."

    if make -j"${JOBS}" 2>&1 | tee build.log; then
        log_success "编译完成。"
    else
        log_error "多线程编译失败，尝试单线程编译以获取更清晰的错误信息..."
        if make -j1 2>&1 | tee build.log; then
            log_success "单线程编译完成。"
        else
            log_error "编译失败！请查看 build.log 了解详情。"
            exit 1
        fi
    fi
}

# ---------- 安装产物 ----------
install_build() {
    print_separator
    log_info "安装 FFmpeg 到: ${PREFIX}"

    if [ ! -d "${PREFIX}" ]; then
        mkdir -p "${PREFIX}"
    fi

    make install
    log_success "安装完成。"
}

# ---------- 输出产物摘要 ----------
print_summary() {
    print_separator
    echo ""
    log_success "FFmpeg Windows 编译成功！"
    echo ""
    log_info "输出目录结构: ${PREFIX}"
    log_info "├── bin/        # DLL 文件及可执行文件"
    log_info "├── include/    # 头文件"
    log_info "└── lib/        # 导入库 (.dll.a / .lib)"
    echo ""

    if [ "${BUILD_TYPE}" = "shared" ]; then
        if [ -d "${PREFIX}/bin" ]; then
            local dll_count
            dll_count=$(find "${PREFIX}/bin" -maxdepth 1 -name "*.dll" 2>/dev/null | wc -l)
            if [ "${dll_count}" -gt 0 ]; then
                log_info "共生成 ${dll_count} 个 DLL 文件:"
                find "${PREFIX}/bin" -maxdepth 1 -name "*.dll" -exec basename {} \; 2>/dev/null | sort | while read -r dll; do
                    echo "        ${dll}"
                done
            else
                log_warn "未在 ${PREFIX}/bin 中检测到 DLL 文件，请检查编译是否成功。"
            fi
        fi
    fi

    echo ""
    print_separator

    log_info "使用说明:"
    log_info "  1. 将 ${PREFIX}/bin 添加到系统 PATH 环境变量"
    log_info "  2. 链接时需要 ${PREFIX}/lib 中的导入库文件"
    echo ""
}

# ---------- 主流程 ----------
main() {
    print_separator
    echo "FFmpeg Windows 动态链接库(DLL)编译脚本"
    echo "运行环境: MSYS2 / MinGW-w64"
    echo "目标平台: Windows (${ARCH})"
    print_separator

    check_dependencies
    print_environment
    clean_build
    configure_build
    compile_build
    install_build
    print_summary
}

main "$@"