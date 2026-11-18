#!/bin/bash
# 给 Mac 上开机自启的 EasyTier 换成打了补丁的版本，让 STUN 和打洞绕开 Shadowrocket 之类代理的 TUN。
#
# 原因：代理 TUN 接管了默认路由，EasyTier 没绑网卡的 UDP 套接字全进了代理，NAT 被误判为对称型，
# 只能经中继服务器转发（带宽受服务器限制）。补丁（scripts/easytier-bind-if.patch）在设置 ET_BIND_IF=auto 时
# 把这些套接字绑到真正上网的物理网卡；代理本身照常工作。
#
# 用法：sudo scripts/patch-mac-easytier.sh          安装（先备份原版为 easytier-core.orig）
#       sudo scripts/patch-mac-easytier.sh restore  还原原版
# 补丁版由 scripts/build-easytier.sh mac 编译。期间 EasyTier 会重启几秒，经它的 SSH 等连接会断一下。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
cd "$(dirname "$0")/.."
plist=/Library/LaunchDaemons/easytier.plist
bin=/opt/easytier/easytier-core
patched="${EASYTIER_SRC:-$(eval echo ~"${SUDO_USER:-$USER}")/data/src/EasyTier}/target/release/easytier-core"

if [ "${1:-}" = restore ]; then
  [ -f "$bin.orig" ] || { echo "没有找到备份 $bin.orig"; exit 1; }
  cp "$bin.orig" "$bin"
  /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:ET_BIND_IF" "$plist" 2>/dev/null || true
else
  [ -x "$patched" ] || { echo "没有找到补丁版 $patched，先运行 scripts/build-easytier.sh mac"; exit 1; }
  [ -f "$bin.orig" ] || cp "$bin" "$bin.orig"
  cp "$patched" "$bin.new" && mv "$bin.new" "$bin"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:ET_BIND_IF" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:ET_BIND_IF string auto" "$plist"
fi
launchctl bootout system "$plist" 2>/dev/null || true
sleep 1
launchctl bootstrap system "$plist"
sleep 8
"$(dirname "$bin")/easytier-cli" node | grep -E "Stun|Public IPv4" || true
echo "完成。UDP Stun Type 不再是 Symmetric 就说明生效了。"
