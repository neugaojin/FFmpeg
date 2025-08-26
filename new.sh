#!/usr/bin/env bash

# 退出前检查错误
set -e

# --- 配置 ---
# 源码目录
SOURCE_DIR=$(pwd)

# 最终通用二进制文件的安装目录
INSTALL_DIR="/Users/an/workspace/ffmpeg_universal"

# 临时构建目录
BUILD_DIR_ARM64="${SOURCE_DIR}/build_arm64"
BUILD_DIR_X86_64="${SOURCE_DIR}/build_x86_64"

# Homebrew 路径
BREW_PREFIX_ARM64="/opt/homebrew"
BREW_PREFIX_X86_64="/usr/local"

# 通用配置选项
# 注意：我们去掉了 --prefix, --extra-cflags, --extra-ldflags，因为它们在每个架构中是不同的
CONFIGURE_FLAGS=" \
  --enable-shared \
  --disable-static \
  --enable-pic \
  \
  --enable-gpl \
  --enable-nonfree \
  --enable-pthreads \
  \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libvpx \
  --enable-libmp3lame \
  --enable-libopus \
  --enable-libfdk-aac \
  --enable-libvorbis \
  --enable-libass \
  --enable-libfreetype \
  --enable-libfontconfig \
  \
  --enable-version3 \
  --enable-hardcoded-tables \
  --enable-swscale \
  \
  --disable-debug \
  --disable-doc \
  --cc=clang"

# --- 编译 arm64 版本 ---
echo "========================================"
echo "Building for arm64..."
echo "========================================"
mkdir -p "$BUILD_DIR_ARM64"
cd "$SOURCE_DIR"

# 清理之前的构建
if [ -f "Makefile" ]; then
    make distclean || true
fi

./configure \
  --prefix="$BUILD_DIR_ARM64" \
  --arch=arm64 \
  --extra-cflags="-I${BREW_PREFIX_ARM64}/include -arch arm64" \
  --extra-ldflags="-L${BREW_PREFIX_ARM64}/lib -arch arm64" \
  ${CONFIGURE_FLAGS}

make -j$(sysctl -n hw.ncpu)
make install

# --- 编译 x86_64 版本 ---
echo "========================================"
echo "Building for x86_64..."
echo "========================================"
mkdir -p "$BUILD_DIR_X86_64"
cd "$SOURCE_DIR"

make distclean

./configure \
  --prefix="$BUILD_DIR_X86_64" \
  --arch=x86_64 \
  --extra-cflags="-I${BREW_PREFIX_X86_64}/include -arch x86_64" \
  --extra-ldflags="-L${BREW_PREFIX_X86_64}/lib -arch x86_64" \
  ${CONFIGURE_FLAGS}

make -j$(sysctl -n hw.ncpu)
make install

# --- 合并为通用二进制文件 ---
echo "========================================"
echo "Creating Universal Binaries..."
echo "========================================"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/bin"

# 合并动态库 (.dylib)
for lib in "$BUILD_DIR_ARM64"/lib/*.dylib; do
    lib_name=$(basename "$lib")
    echo "Lipo-ing ${lib_name}..."
    lipo -create \
      "$BUILD_DIR_ARM64/lib/$lib_name" \
      "$BUILD_DIR_X86_64/lib/$lib_name" \
      -output "$INSTALL_DIR/lib/$lib_name"
done

# 合并可执行文件 (ffmpeg, ffplay, ffprobe)
for bin_file in ffmpeg ffplay ffprobe; do
    echo "Lipo-ing ${bin_file}..."
    lipo -create \
      "$BUILD_DIR_ARM64/bin/$bin_file" \
      "$BUILD_DIR_X86_64/bin/$bin_file" \
      -output "$INSTALL_DIR/bin/$bin_file"
done

# 复制头文件
echo "Copying headers..."
cp -R "$BUILD_DIR_ARM64/include" "$INSTALL_DIR/"

# --- 完成 ---
echo "========================================"
echo "Universal FFmpeg build complete!"
echo "Files are in: $INSTALL_DIR"
echo "========================================"

# 验证结果
echo "Verifying binaries..."
file "$INSTALL_DIR/bin/ffmpeg"
file "$INSTALL_DIR/lib/libavcodec.dylib"