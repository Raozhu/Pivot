#!/usr/bin/env python3
"""诊断工具：列出 usbmuxd 上的设备，并试连 iPad 上的 Pivot 端口。

用法：python3 scripts/muxprobe.py [端口]
"""
import plistlib
import socket
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 47101


def call(sock, msg):
    body = plistlib.dumps(msg)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)
    header = sock.recv(16, socket.MSG_WAITALL)
    (length,) = struct.unpack("<I", header[:4])
    return plistlib.loads(sock.recv(length - 16, socket.MSG_WAITALL))


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("/var/run/usbmuxd")
    return s


base = {"ClientVersionString": "pivot-probe", "ProgName": "pivot-probe", "kLibUSBMuxVersion": 3}
devices = call(connect(), dict(base, MessageType="ListDevices")).get("DeviceList", [])
for d in devices:
    p = d["Properties"]
    print("设备", d["DeviceID"], p.get("ConnectionType"), p.get("SerialNumber"))
    if p.get("ConnectionType") != "USB":
        continue
    s = connect()
    swapped = ((PORT & 0xFF) << 8) | (PORT >> 8)
    reply = call(s, dict(base, MessageType="Connect", DeviceID=d["DeviceID"], PortNumber=swapped))
    code = reply.get("Number")
    meaning = {0: "成功", 2: "设备不存在", 3: "端口拒绝连接（iPad 上的 Pivot 没在监听）", 6: "协议版本不符"}.get(code, "未知")
    print("  连接端口", PORT, "→", code, meaning)
    if code == 0:
        s.settimeout(2)
        try:
            data = s.recv(64)
            print("  收到", len(data), "字节：", data[:32].hex())
        except Exception as e:
            print("  2 秒内没有数据：", e)
    s.close()
