// 手指触控部分移植自 WiredPad（MIT 协议，https://github.com/takpika/WiredPad）。
#include "PivotTouchDriver.h"
#include <DriverKit/IOLib.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSBoolean.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/OSString.h>
#include <HIDDriverKit/IOHIDEventServiceKeys.h>
#include <HIDDriverKit/IOHIDDigitizerStructs.h>

namespace {
constexpr uint32_t maxContacts = 10;
constexpr uint32_t contactSize = 6;
/// 报告 1：报告号 + 10 个触点（各 6 字节：标志、编号、x、y）+ 触点数
constexpr uint32_t reportSize = 1 + maxContacts * contactSize + 1;
}

struct PivotTouchDriver_IVars {
    uint32_t reportCount;
    uint32_t dispatchCount;
    bool previousDown[maxContacts];
    uint16_t previousX[maxContacts];
    uint16_t previousY[maxContacts];
};

static void putNumber(OSDictionary *properties, const char *key, uint64_t value) {
    if (OSNumber *number = OSNumber::withNumber(value, 32)) {
        properties->setObject(key, number);
        number->release();
    }
}

bool PivotTouchDriver::init() {
    if (!super::init()) return false;
    ivars = IONewZero(PivotTouchDriver_IVars, 1);
    return ivars != nullptr;
}

void PivotTouchDriver::free() {
    if (ivars) IODelete(static_cast<PivotTouchDriver_IVars *>(ivars), PivotTouchDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(PivotTouchDriver, Start) {
    kern_return_t result = Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;

    // 关键一步（WiredPad 的发现）：WindowServer 只认触控服务自己身上的 displayUUID（小写开头），
    // 写在虚拟设备上不算。Pivot 把显示器编号放在 CGDirectDisplayID、UUID 放在 SerialNumber 里传过来。
    if (OSDictionary *properties = OSDictionary::withCapacity(4)) {
        OSContainer *display = nullptr;
        if (provider->SearchProperty("CGDirectDisplayID", "IOService", kIOServiceSearchPropertyParents, &display) == kIOReturnSuccess && display) {
            if (OSNumber *number = OSDynamicCast(OSNumber, display)) {
                properties->setObject("CGDirectDisplayID", number);
                properties->setObject("DisplayIntegrated", kOSBooleanTrue);
                OSContainer *serial = nullptr;
                if (provider->SearchProperty("SerialNumber", "IOService", kIOServiceSearchPropertyParents, &serial) == kIOReturnSuccess && serial) {
                    if (OSString *uuid = OSDynamicCast(OSString, serial)) properties->setObject("displayUUID", uuid);
                    serial->release();
                }
            }
            display->release();
        }
        SetProperties(properties);
        properties->release();
    }
    RegisterService();
    return kIOReturnSuccess;
}

bool PivotTouchDriver::handleStart(IOService *provider) {
    OSDictionary *properties = OSDictionary::withCapacity(1);
    if (!properties) return false;
    properties->setObject(kIOHIDEventDriverHandlesReport, kOSBooleanTrue);
    const kern_return_t result = SetProperties(properties);
    properties->release();
    return result == kIOReturnSuccess && super::handleStart(provider);
}

void PivotTouchDriver::handleReport(uint64_t timestamp, uint8_t *report, uint32_t reportLength,
                                    IOHIDReportType type, uint32_t reportID) {
    auto *state = static_cast<PivotTouchDriver_IVars *>(ivars);
    ++state->reportCount;
    if (type != kIOHIDReportTypeInput || reportID != 1 || !report) return;
    const uint32_t base = reportLength == reportSize && report[0] == 1 ? 1 : 0;
    if (reportLength < base + maxContacts * contactSize + 1) return;

    IOHIDDigitizerTouchData touches[maxContacts] = {};
    uint32_t count = 0;
    for (uint32_t i = 0; i < maxContacts; ++i) {
        const uint32_t offset = base + i * contactSize;
        const bool down = (report[offset] & 1) != 0;
        if (!down && !state->previousDown[i]) continue;
        const uint16_t x = down ? uint16_t(report[offset + 2] | (report[offset + 3] << 8)) : state->previousX[i];
        const uint16_t y = down ? uint16_t(report[offset + 4] | (report[offset + 5] << 8)) : state->previousY[i];
        auto &touch = touches[count++];
        touch.identifier = i;
        // 0…32767 → 0…1（16.16 定点），相对于绑定的显示器
        touch.x = static_cast<IOFixed>((uint32_t(x) * 65536U) / 32767U);
        touch.y = static_cast<IOFixed>((uint32_t(y) * 65536U) / 32767U);
        touch.inRange = down;
        touch.touch = down;
        touch.touchValid = true;
        touch.touchChanged = down != state->previousDown[i];
        touch.positionChanged = x != state->previousX[i] || y != state->previousY[i];
        touch.rangeChanged = touch.touchChanged;
        state->previousDown[i] = down;
        state->previousX[i] = x;
        state->previousY[i] = y;
    }
    if (!count) return;
    const kern_return_t result = dispatchDigitizerTouchEvent(timestamp, touches, count);
    ++state->dispatchCount;
    // 前几次的情况记到注册表里，方便用 ioreg 排查
    if (state->dispatchCount <= 8 || result != kIOReturnSuccess) {
        if (OSDictionary *properties = OSDictionary::withCapacity(3)) {
            putNumber(properties, "PivotDispatchCount", state->dispatchCount);
            putNumber(properties, "PivotTouchCount", count);
            putNumber(properties, "PivotDispatchResult", result);
            SetProperties(properties);
            properties->release();
        }
        IOLog("PivotTouchDriver dispatch=%u contacts=%u result=0x%x\n", state->dispatchCount, count, result);
    }
}
