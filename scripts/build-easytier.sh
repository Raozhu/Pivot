#!/bin/bash
# 编译 iPad 端内嵌的 EasyTier（远程连接用），产物放到 Vendor/EasyTier/libeasytier_ffi.a。
# 用法：scripts/build-easytier.sh        iPad 静态库
#       scripts/build-easytier.sh mac    Mac 版 easytier-core（配合 scripts/patch-mac-easytier.sh）
# 两者都打上 scripts/easytier-bind-if.patch（让 STUN 和打洞绕开代理 TUN；放大 UDP 端口转发的缓冲，承载视频分片）。
# 需要 rustup（https://rustup.rs）和 protoc（brew install protobuf）。
# 版本要和 Mac、服务器上跑的 EasyTier 一致，默认 v2.6.4；可用 EASYTIER_VERSION 覆盖。
set -euo pipefail
cd "$(dirname "$0")/.."
version="${EASYTIER_VERSION:-v2.6.4}"
src="${EASYTIER_SRC:-$HOME/data/src/EasyTier}"
[ -d "$src" ] || git clone --depth 1 --branch "$version" https://github.com/EasyTier/EasyTier.git "$src"
( cd "$src"
  git fetch --depth 1 origin tag "$version" >/dev/null 2>&1 || true
  git checkout -q "$version"
  git apply --check "$OLDPWD/scripts/easytier-bind-if.patch" 2>/dev/null && git apply "$OLDPWD/scripts/easytier-bind-if.patch"
  # 官方 FFI 只出动态库；iOS 上要静态库
  sed -i '' 's/crate-type = \["cdylib"\]/crate-type = ["staticlib"]/' easytier-contrib/easytier-ffi/Cargo.toml
  source "$HOME/.cargo/env"
  if [ "${1:-}" = mac ]; then
    cargo build --release -p easytier --bin easytier-core
    exit 0
  fi
  rustup target add aarch64-apple-ios >/dev/null
  cargo build --release -p easytier-ffi --target aarch64-apple-ios )
[ "${1:-}" = mac ] && { echo "已生成 $src/target/release/easytier-core（EasyTier $version，含补丁）"; exit 0; }
mkdir -p Vendor/EasyTier
cp "$src/target/aarch64-apple-ios/release/libeasytier_ffi.a" Vendor/EasyTier/
echo "已生成 Vendor/EasyTier/libeasytier_ffi.a（EasyTier $version）"
