#!/usr/bin/env bash

export PKG_CONFIG_PATH=""

ARCH="arm64"
IOS_MIN_VERSION="13.0"
PREFIX="/Users/bytedance/workspace/ffmpeg_ios/$ARCH"

SYSROOT=$(xcrun -sdk iphoneos --show-sdk-path 2>/dev/null)

if [ -z "$SYSROOT" ] || [ ! -d "$SYSROOT" ]; then
    echo "错误: 未找到 iphoneos SDK 路径"
    echo "请确保已安装完整的 Xcode（非仅 Command Line Tools）。"
    exit 1
fi

CC="xcrun -sdk iphoneos clang"
CXX="xcrun -sdk iphoneos clang++"
AR="xcrun -sdk iphoneos ar"
NM="xcrun -sdk iphoneos nm"
STRIP="xcrun -sdk iphoneos strip"
RANLIB="xcrun -sdk iphoneos ranlib"
METALCC="xcrun -sdk iphoneos metal"
METALLIB="xcrun -sdk iphoneos metallib"

echo "========================================"
echo "开始编译 FFmpeg for iOS ($ARCH)"
echo "SYSROOT:  $SYSROOT"
echo "PREFIX:   $PREFIX"
echo "MIN_VER:  $IOS_MIN_VERSION"
echo "========================================"

make distclean

./configure \
  --prefix="$PREFIX" \
  --enable-cross-compile \
  --target-os=darwin \
  --arch="$ARCH" \
  --sysroot="$SYSROOT" \
  --cc="$CC" \
  --cxx="$CXX" \
  --ar="$AR" \
  --nm="$NM" \
  --strip="$STRIP" \
  --ranlib="$RANLIB" \
  --metalcc="$METALCC" \
  --metallib="$METALLIB" \
  \
  --enable-static \
  --disable-shared \
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
  --disable-programs \
  --disable-ffplay \
  --disable-sdl2 \
  --disable-libxcb \
  --disable-xlib \
  --disable-appkit \
  \
  --extra-cflags="-arch $ARCH -miphoneos-version-min=$IOS_MIN_VERSION" \
  --extra-ldflags="-arch $ARCH -miphoneos-version-min=$IOS_MIN_VERSION"


if command -v sysctl >/dev/null 2>&1; then
    CORES=$(sysctl -n hw.ncpu)
else
    CORES=$(nproc 2>/dev/null || echo 4)
fi

make -j${CORES} || make -j1

make install

echo "========================================"
echo "编译完成！输出产物位于: $PREFIX"
echo "  lib/    -> 静态库 (.a)"
echo "  include/ -> 头文件"
echo "========================================"
