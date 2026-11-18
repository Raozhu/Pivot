#!/bin/bash
# 用法：scripts/run-pad.sh [设备标识]
# 安装并启动 iPad 端，控制台输出写到 build/pad.log（后台运行）。
cd "$(dirname "$0")/.."
device="${1:?用法：scripts/run-pad.sh <iPad 的设备标识，见 xcrun devicectl list devices>}"
pkill -f "devicectl device process launch.*com.example.pivot" 2>/dev/null
xcrun devicectl device install app --device "$device" build/Build/Products/Debug-iphoneos/Pivot.app >build/pad-install.log 2>&1 || { tail -5 build/pad-install.log; exit 1; }
nohup xcrun devicectl device process launch --device "$device" --terminate-existing --console com.example.pivot >build/pad.log 2>&1 &
echo "iPad 端已安装并启动，日志 build/pad.log"
