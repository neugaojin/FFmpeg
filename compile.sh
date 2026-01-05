#!/usr/bin/env bash

export PKG_CONFIG_PATH=""

echo "========================================"
echo "$PKG_CONFIG_PATH"
echo "========================================"


# 清理旧的构建产物，防止版本号残留
make distclean

./configure \
  --prefix=/Users/bytedance/workspace/ffmpeg \
  --enable-shared \
  --disable-static \
  --enable-pic \
  --install-name-dir=@rpath \
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
  --cc=clang \
  --extra-cflags="-I/usr/local/include" \
  --extra-ldflags="-liconv"


# 使用所有可用的CPU核心进行编译
make -j$(sysctl -n hw.ncpu)

# 编译完成后，安装到 configure 中指定的 prefix 路径
sudo make install