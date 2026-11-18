#!/bin/bash
# 打印随航虚拟触摸屏服务累计收到的触摸事件数（没有该服务时打印 0）。
# 用来判断「用户是否真的在随航画面上用手指触摸过」。
tmp=$(mktemp)
hidutil dump system >"$tmp" 2>/dev/null
python3 -I - "$tmp" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
n = 0
for s in d.get("ServiceRecords", []):
    if s.get("PrimaryUsagePage") == 13 and s.get("PrimaryUsage") == 4:
        n = max(n, (s.get("EventTypeCounts") or {}).get("Digitizer", 0))
print(n)
EOF
rm -f "$tmp"
