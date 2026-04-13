#!/usr/bin/env bash

# ==============================================================================
# FFmpeg Android Cross-Compile Script
# ==============================================================================

# 1. 设置你的 NDK 路径 (如果没有配置 ANDROID_NDK_HOME 环境变量，请手动修改此处)
NDK_PATH=${ANDROID_NDK_HOME:-"/Users/bytedance/resource/android_sdk/ndk/21.3.6528147"}

if [ ! -d "$NDK_PATH" ]; then
    echo "错误: 未找到 NDK 路径: $NDK_PATH"
    echo "请先下载 Android NDK (推荐 NDK r21 以上)，并正确配置此脚本中的 NDK_PATH 变量。"
    exit 1
fi

# 2. 设置目标架构 (这里以目前最常用的 arm64-v8a 为例)
ARCH="aarch64"
CPU="armv8-a"
API="21" # 最低支持的 Android API Level (Android 5.0)

# macOS 下的 NDK 工具链路径
TOOLCHAIN="$NDK_PATH/toolchains/llvm/prebuilt/darwin-x86_64"
SYSROOT="$TOOLCHAIN/sysroot"

# NDK r19 及以上版本推荐直接使用 clang 包装器，它内置了目标架构和 API Level
CC="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"
AR="$TOOLCHAIN/bin/llvm-ar"
NM="$TOOLCHAIN/bin/llvm-nm"
STRIP="$TOOLCHAIN/bin/llvm-strip"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"

# 编译输出目录
PREFIX="/Users/bytedance/workspace/ffmpeg_android/$ARCH"

echo "========================================"
echo "开始编译 FFmpeg for Android ($ARCH)"
echo "NDK_PATH: $NDK_PATH"
echo "PREFIX:   $PREFIX"
echo "========================================"

# 清理旧的构建产物，防止版本号残留
make distclean

# 配置编译选项
./configure \
  --prefix="$PREFIX" \
  --target-os=android \
  --arch="$ARCH" \
  --cpu="$CPU" \
  --enable-cross-compile \
  --sysroot="$SYSROOT" \
  --cc="$CC" \
  --cxx="$CXX" \
  --ar="$AR" \
  --nm="$NM" \
  --strip="$STRIP" \
  --ranlib="$RANLIB" \
  \
  --enable-shared \
  --disable-static \
  --enable-pic \
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
  --extra-cflags="-Os -fpic -march=$CPU" \
  --extra-ldflags=""


# 获取CPU核心数（兼容不同系统）
if command -v sysctl >/dev/null 2>&1; then
    CORES=$(sysctl -n hw.ncpu)
else
    CORES=$(nproc 2>/dev/null || echo 4)
fi

# 使用所有可用的CPU核心进行编译
make -j${CORES}

# 编译完成后安装
make install

echo "========================================"
echo "编译完成！输出产物位于: $PREFIX"
echo "提示: 如果你要在 Android 命令行直接运行生成的 bin/ffmpeg 可执行文件，"
echo "由于启用了动态库(--enable-shared)，你需要将 lib/ 下的所有 .so 文件也推送到手机，"
echo "并在运行前设置环境变量: export LD_LIBRARY_PATH=/你的so存放路径"
echo "========================================"
