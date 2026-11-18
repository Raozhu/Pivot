#!/bin/bash
# 用法：scripts/run-mac.sh [秒数]
# 直接从终端启动 Mac 端（继承终端的屏幕录制授权），日志写到 build/host.log。
# 给了秒数就在到时后自动退出，方便自测。
# 环境变量 PIVOT_SELFTEST=stats 定时打印统计；=rotate 还会模拟 iPad 来回旋转。
cd "$(dirname "$0")/.."
pkill -x Pivot 2>/dev/null
sleep 0.3
build/Build/Products/Debug/Pivot.app/Contents/MacOS/Pivot >build/host.log 2>&1 &
pid=$!
if [ -n "${1:-}" ]; then
  sleep "$1"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat build/host.log
else
  echo "Pivot 已启动，进程 $pid，日志 build/host.log"
fi
