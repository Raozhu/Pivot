#!/bin/bash
# 用法：scripts/build.sh mac | pad
# 只输出错误和最终结果；完整日志在 build/last-<目标>.log
set -uo pipefail
cd "$(dirname "$0")/.."
target="${1:-mac}"
mkdir -p build
if [ ! -d Pivot.xcodeproj ] || [ project.yml -nt Pivot.xcodeproj ]; then
  xcodegen generate >/dev/null
fi
case "$target" in
  mac)
    args=(-scheme PivotMac -destination "platform=macOS") ;;
  pad)
    args=(-scheme PivotPad -destination "generic/platform=iOS" -allowProvisioningDeviceRegistration) ;;
  *)
    echo "未知目标：$target"; exit 2 ;;
esac
xcodebuild -project Pivot.xcodeproj "${args[@]}" -configuration Debug -derivedDataPath build \
  -allowProvisioningUpdates build >"build/last-$target.log" 2>&1
status=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "build/last-$target.log" | sed "s|$PWD/||" | sort -u | cut -c1-300 | head -60
[ $status -eq 0 ] && [ "$target" = mac ] || exit $status

# 原生触控：编译触摸屏驱动并放进 Pivot.app，再带上权限重新签名。
# 免费开发团队拿不到这些权限，自签名的权限只有在关闭 SIP、关闭 AMFI（boot-args amfi_get_out_of_my_way=1）
# 并开启 systemextensionsctl developer 后才有效；否则带权限的 Pivot 会被系统拒绝启动，所以默认不做这一步。
# 用 PIVOT_NATIVE_TOUCH=1 scripts/build.sh mac 打开。
[ "${PIVOT_NATIVE_TOUCH:-0}" = 1 ] || exit 0
xcodebuild -project Pivot.xcodeproj -scheme PivotTouchDriver -configuration Debug \
  -destination "generic/platform=DriverKit" -derivedDataPath build build >build/last-driver.log 2>&1 \
  || { grep -E "error:" build/last-driver.log | head -20; echo "驱动编译失败"; exit 1; }
app=build/Build/Products/Debug/Pivot.app
dext=build/Build/Products/Debug-driverkit/PivotTouchDriver.dext
id=com.example.pivot.host.touchdriver
# 沿用 Xcode 签 Pivot 时用的那张开发证书，系统授权（屏幕录制、辅助功能）才不会失效
identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[ -n "$identity" ] || { echo "读不到 Pivot 的签名证书"; exit 1; }
rm -rf "$app/Contents/Library/SystemExtensions"
mkdir -p "$app/Contents/Library/SystemExtensions"
ditto "$dext" "$app/Contents/Library/SystemExtensions/$id.dext"
codesign --force --sign "$identity" --entitlements Driver/PivotTouchDriver.entitlements \
  "$app/Contents/Library/SystemExtensions/$id.dext" || exit 1
ents=build/pivot-native.entitlements
codesign -d --entitlements :- "$app" >"$ents" 2>/dev/null || cp Support/Mac-Native.entitlements "$ents"
for key in com.apple.developer.hid.virtual.device com.apple.developer.system-extension.install; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$ents" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ents"
done
codesign --force --sign "$identity" --entitlements "$ents" "$app" || exit 1
echo "已打包触摸屏驱动并带权限签名（$identity）"
