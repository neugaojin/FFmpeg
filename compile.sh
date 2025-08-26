#!/usr/bin/env bash

./configure \
  --prefix=/Users/an/workspace/ffmpeg \
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
  --cc=clang \
  --extra-cflags="-I/usr/local/include" \
  --extra-ldflags="-L/usr/local/lib"


# 使用所有可用的CPU核心进行编译
make -j$(sysctl -n hw.ncpu)

# 编译完成后，安装到 configure 中指定的 prefix 路径
sudo make install