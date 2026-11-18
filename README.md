**简体中文** | [English](README.en.md)

# Pivot

**能竖屏、能远程，而且保留 macOS 27 原生触控的随航。**

Pivot 把 iPad 变成 Mac 的一块屏幕，手指直接在上面操作 macOS。它补上了系统自带随航（Sidecar）做不到的两件事，而且不牺牲随航最好的那一点：触控手感。

> 📚 **这是一个技术参考仓库，不是开箱即用的产品。**
> Pivot 是个人项目，很多逻辑是按作者自己的设备写的：iPad 的分辨率和型号、Mac 的网络环境、签名和组网配置都有写死的地方，不保证换一台设备就能直接编译运行，也不提供安装包和支持。
> 这个仓库的价值在于**它证明了哪些事情做得到、具体怎么做到的**：竖屏虚拟显示器、在 macOS 27 上给虚拟显示器接上原生触控、接收随航的原始触点、把远程组网塞进一个 iPad App、为跟手设计的 UDP 实时通道。重点请看[它是怎么做到的](#它是怎么做到的)，代码里关键位置都有中文注释。

## 为什么做 Pivot

macOS 27 给随航加上了原生触控：手指在 iPad 上滚动、捏合、长按，macOS 当成真正的触摸屏来处理，手感很好。但随航有两个硬伤：

- **只能横屏**。iPad 竖起来看文档、写代码、刷网页才舒服，随航不支持。
- **只能在身边用**。iPad 必须插线，或者和 Mac 在同一个地方。

市面上的远程桌面和第三方副屏工具能竖屏、能远程，但触控都是把手指「翻译」成鼠标：点一下是点击，拖一下是拖拽，滚动、惯性、捏合都是模拟出来的，和随航的原生手感差一截。

**Pivot 同时做到三件事：竖屏、远程、原生触控。**

## 卖点

- 📱 **真竖屏**：Mac 上多出的那块屏，分辨率和 iPad 物理像素逐点对应。转一下 iPad，Mac 那块屏就跟着横竖切换，窗口不乱跑。
- ✋ **macOS 27 原生触控**：手指事件直接交给 macOS 自己的触摸屏通路处理，滚动惯性、捏合缩放、长按菜单全是系统原生行为，和随航同一套。
- 🌏 **随时随地连回你的 Mac**：有线 › 局域网 › 远程，自动选最快的那条，换线不断画面。远程组网内置在 iPad 应用里，不用另装 VPN。
- ⚡ **为跟手而做**：画面和触控走加密 UDP 实时通道，有纠错、不重传旧画面、触控冗余发送；网络紧张时先保帧率、降清晰度，iPad 再用苹果的低延迟超分辨率放大回来。
- ✏️ **Apple Pencil**：压感、倾斜、悬停移动指针，用笔时忽略手掌。
- ⌨️ **像本地一样好用**：
  - 外接键盘和触控板直接作用到 Mac。
  - 点到输入框自动弹出 iPad 屏幕键盘。
  - 声音传到 iPad，一键开关。
  - 剪贴板双向同步。
  - 每台 iPad 的屏幕排列位置都会被记住。
- 🖥 **三种用法**：
  - 扩展屏：多一块屏。
  - 镜像：iPad 显示 Mac 主屏。
  - 仅 iPad：Mac 所有窗口都集中到 iPad 上，适合远程时只用 iPad。

> ⚠️ **先看限制**：Pivot 需要 **macOS 27.3 或更新**。原生触控依赖一个 DriverKit 驱动和受限权限：没有付费开发者账号时，只能在**关闭 SIP 和 AMFI** 的 Mac 上使用。有 99 美元付费账号的话，可以申请权限，不关安全设置。详见[系统要求与限制](#系统要求与限制)。

---

## 它是怎么做到的

### 1. 竖屏：不用随航的显示通道，自己建一块屏

随航的显示器方向是写死的。我们试过用 SkyLight 私有函数 `SLSSetDisplayRotation` 强制旋转随航屏：窗口服务器接受了，但随航换算触点时不管旋转，90° 和 270° 下触点都对不上，iPad 那边的随航界面还会把横的画幅缩在中间。所以 Pivot 绕开了随航的显示通道：

- **虚拟显示器**：用 CoreGraphics 的私有类 `CGVirtualDisplay` 创建一块系统认可的显示器，分辨率等于 iPad 的物理像素。
- **横竖两套模式表**：横、竖模式混在同一张表里时，系统会把一部分模式标成不可切换，所以分成两张表。iPad 一转，Pivot 给同一块显示器整体换表，目标模式排在表首。系统通常直接落到它上面（约 0.2 秒，窗口不动）；没落上就显式切换；表迟迟没装上就重建显示器，身份不变，系统会把窗口放回原处。每一步都以「当前模式是否已是目标」为准。
- **推流**：ScreenCaptureKit 采集这块屏 → VideoToolbox 硬件 HEVC 低延迟编码（编码器不攒帧）→ iPad 硬件解码，收到即显示。对端跟不上时只保留最新一帧，延迟不会累积。

另外还有一个「随航竖屏」模式，给想保留随航连接方式的人用：照常用随航把 iPad 接成横屏副屏（iPad 开旋转锁定），Pivot 建一块竖屏虚拟显示器，把它的画面转 90° 全屏铺在随航屏上。竖屏贴着主屏排列，随航屏挪开，只留一小段接缝并在那里挡住光标；落到随航屏上的窗口会自动搬走。

### 2. 原生触控：让 macOS 把虚拟显示器当成一块触摸屏

macOS 27 的原生触控只认「绑定了某块显示器的触摸屏」。Pivot 给自己的虚拟显示器造了一块：

1. **虚拟触摸屏**：Mac 应用用 `IOHIDUserDevice` 注册一块 10 点 HID 触摸屏，把显示器编号和显示器 UUID 放进设备属性。虚拟显示器的 UUID 公开接口取不到（返回空），要用私有的 `CGSCopyDisplayUUID`。
2. **DriverKit 驱动绑定显示器**：Pivot 自带一个 DriverKit 驱动（`Driver/`），匹配这块虚拟触摸屏，把显示器 UUID 以 `displayUUID`（小写开头）写到**驱动自己的触控服务**上，再把 HID 报告变成数字化仪触控事件。只写在虚拟设备上的话，WindowServer 会当成「不支持的服务」丢掉，这是能不能成的关键。做法参考了 [WiredPad](https://github.com/takpika/WiredPad)（MIT）。
3. **iPad 上的手指**经网络传到 Mac，按归一化坐标填进这块触摸屏的报告。之后怎么滚动、怎么缩放、要不要弹菜单，全由 macOS 自己决定，所以和随航是同一套手感。

驱动没生效时，Pivot 自动退回「合成手势」后端：自己识别手势，再投递鼠标、滚动、缩放、旋转事件。能用，但手感比原生差一些。Pencil、悬停和外接触控板始终走合成后端，因为它们需要压感、倾斜和指针语义。

### 3. 随航竖屏模式下怎么拿到触点

随航竖屏模式里，手指按在随航屏上，但 Pivot 要的是转过 90° 以后的触点。macOS 27 的随航触控**不经过任何事件监听**（`CGEventTap`、`NSEvent` 全局监听都拿不到），只交给手指下那个窗口上挂的手势识别器（Apple TN3212）。

手指下正好是 Pivot 铺画面的那层窗口，所以 Pivot 在上面挂了一个 `NSGestureRecognizer`（`SidecarTouchRecognizer`，只收直接触控），拿到原始触点后：

1. 坐标转 90°；
2. 送进绑定到竖屏虚拟显示器的虚拟触摸屏，也就是上面第 2 点的原生通路；
3. 驱动没生效时交给合成手势。

`Info.plist` 里设了 `NSIsTouchNative`，让系统不再把这些触控另外模拟成鼠标。

### 4. 远程：一个 App 里装下组网

- **组网**：iPad 端内嵌了 [EasyTier](https://easytier.cn)（`easytier-ffi` 静态库），以不建网卡的模式运行在 Pivot 进程里，所以不需要 NetworkExtension 权限，免费开发者账号也能用。插线连接时，Mac 把组网参数（只经 USB 传）交给 iPad；之后 iPad 把本机 47110 端口的 TCP 和 UDP 转发到 Mac 的虚拟 IP。能打洞就直连，打不通走中继，按延迟优先选路。
- **安全**：
  - 配对密钥由 iPad 生成，只在插线握手时交给 Mac。能无线连上的，一定是插线配对过的设备。
  - 控制通道用 TLS 预共享密钥双向认证。
  - 实时通道用 ChaCha20‑Poly1305 加密：密钥由配对密钥经 HKDF 派生，每个会话随机加盐，带重放窗口。
- **UDP 实时通道**（跟手的关键）：
  - **分片与纠错**：画面按 1100 字节分片，加交错异或纠错片，纠错比例按 iPad 回报的丢包率在 10%～40% 之间自动调。
  - **不等丢失的帧**：补不回来的帧直接跳过，等下一个关键帧，不会因为一个包卡住后面所有画面。关键帧自带参数集。
  - **平滑发送**：Mac 端用令牌桶发包，不把一整帧瞬间塞进 Wi‑Fi 队列。
  - **触控优先**：每个触控包捎带前两包，按下、抬起再补发两次；网络层标成视频优先级。
  - **自动退回**：UDP 3 秒不通就退回 TLS 连接，画面不中断。
- **流畅优先**：
  - 无线时尽量保持满帧（远程最高 60 帧）。带宽紧张时降的是编码分辨率，iPad 拉伸铺满；只有码率极低时才降帧率。
  - iPad 支持时，用 iPadOS 26 的 `VTLowLatencySuperResolutionScaler` 把小画面实时放大，每帧约 2 毫秒。处理跟不上时那一帧不放大，绝不排队。
  - 手指拖动时，可选用系统预测的触点位置（往前看约一帧）。

### 5. 其他

- **有线**：通过系统自带的 usbmuxd 直连 iPad 上的端口，全程不经过网络，延迟约 10 毫秒。
- **声音**：独立的 ScreenCaptureKit 流只取系统声音，编成 Opus（48 kHz 立体声，每包 10 毫秒，约 96 kbps），远程时和画面一起走 UDP。iPad 只留 20～120 毫秒缓冲，宁可断一瞬也不让声音越拖越晚。
- **剪贴板**：Mac 一复制，iPad 就能粘贴。iPad 平时不读剪贴板，免得频繁弹 iOS 的「允许粘贴」提示；你在 Pivot 里按 ⌘V 时，才把 iPad 上新复制的内容先发给 Mac，再发按键。
- **自动弹键盘**：Mac 用辅助功能接口检查当前焦点是不是能输入文字的地方，iPad 刚点过画面才弹屏幕键盘；接了外接键盘就不弹。
- **屏幕位置**：系统不一定会替虚拟显示器记住排列位置。Pivot 记下每台 iPad 在主屏的哪一边、沿边的位置比例，重连或旋转后放回原处。

---

## 系统要求与限制

### 硬性要求

| 项目 | 要求 |
|---|---|
| Mac 系统 | **macOS 27.3 或更新**。原生触摸屏通路是 macOS 27 才有的，Pivot 依赖 27.3 上的行为 |
| Mac 硬件 | Apple 芯片的 Mac（开发与实测机：M5 Pro MacBook Pro） |
| iPad 系统 | iPadOS 17 或更新；超分辨率需要 iPadOS 26 及支持的设备 |
| 原生触控 | Pivot 的 DriverKit 驱动必须生效。二选一：**关闭 SIP 和 AMFI 后自签名**，或**用付费开发者账号拿到 Apple 批准的权限** |
| 远程 | Mac 上要装好并运行 EasyTier（手动指定虚拟 IP）。iPad 端不用另装 |

### 需要知道的限制

- **关 SIP 和 AMFI 的代价**：会大幅降低整台 Mac 的安全性，可能导致 iPad App 打不开、Apple Pay 或 DRM 内容失效、安全软件报警等问题。只建议在自己的机器上这样做。
- **不开原生触控也能用**：驱动没生效时自动退回合成手势，能用，但手感和系统原生的不完全一样。
- **用了私有接口**：`CGVirtualDisplay`、`CGSCopyDisplayUUID` 等。不能上架 App Store，系统更新后可能需要调整。
- **iPad 应用有效期**：免费开发者账号签名的 iPad 应用 7 天后过期，要重新插线安装；付费账号是 1 年。
- **后台会断开**：iPad 上的 Pivot 退到后台就会断开，因为 iPadOS 会冻结后台应用的网络。
- **远程画质看线路**：打洞成功走直连；失败时经中继转发，受服务器带宽限制，画质会明显下降。Mac 上开着代理软件的 TUN 模式会让打洞失败，见下文的补丁。
- **和「通用控制」冲突**：同一 Apple ID 的 iPad 在旁边时，鼠标推到屏幕边缘可能被通用控制接管。建议在「系统设置 › 显示器 › 高级」里关掉「推过显示器边缘以连接附近的 Mac 或 iPad」。
- **Mac 的扬声器照常出声**：传声音到 iPad 时，Mac 本机不会静音。

---

## 启用原生触控

原生触控需要两类受限权限同时生效：

- **Mac 应用**：`com.apple.developer.hid.virtual.device`，用于创建虚拟 HID 触摸屏。
- **DriverKit 驱动**：`com.apple.developer.driverkit`、`com.apple.developer.driverkit.transport.hid`、`com.apple.developer.driverkit.family.hid.eventservice`。

系统只认 Apple 签发的这些权限，所以有两条路。

### 方式 A：没有付费账号 → 关闭 SIP 和 AMFI，自签名

1. 进入恢复模式，在终端运行 `csrutil disable`，重启。
2. 关闭 AMFI，然后重启：
   ```bash
   sudo nvram boot-args="amfi_get_out_of_my_way=1"
   ```
3. 打开系统扩展开发者模式：
   ```bash
   systemextensionsctl developer on
   ```
4. 带驱动编译 Mac 端：
   ```bash
   PIVOT_NATIVE_TOUCH=1 scripts/build.sh mac
   ```
5. 把 `Pivot.app` 放到「应用程序」文件夹后启动。在「系统设置 › 通用 › 登录项与扩展 › 驱动程序扩展」里同意 Pivot 的驱动。
6. Mac 菜单栏里的触控后端显示为「原生触摸屏」，就说明生效了。

恢复安全设置：运行 `sudo nvram -d boot-args`，重启，再进恢复模式运行 `csrutil enable`。恢复后要换回不带 `PIVOT_NATIVE_TOUCH` 编译的版本（带受限权限签名的会被系统拒绝启动），触控回到合成手势。

### 方式 B：有 99 美元付费开发者账号 → 申请权限，SIP 和 AMFI 保持开启

1. **换成你自己的标识**：把 `project.yml` 里的 `bundleIdPrefix` 和 `DEVELOPMENT_TEAM` 换成你自己的。共有三个 Bundle ID：
   - Mac 应用 `<前缀>.pivot.host`
   - 驱动 `<前缀>.pivot.host.touchdriver`
   - iPad 应用 `<前缀>.pivot`
   
   `Sources/Mac/Input/TouchDriverExtension.swift` 和 `scripts/build.sh` 里的驱动标识也要同步改。
2. **注册 App ID**：在开发者后台为 Mac 应用和驱动各建一个 App ID。Mac 应用勾选 System Extension 能力（`com.apple.developer.system-extension.install`），付费账号可以直接勾选。
3. **申请受限权限**：在 Apple 的 [System Extension 与 DriverKit 申请页面](https://developer.apple.com/contact/request/system-extension/) 提交，写明用途：虚拟触摸屏，把 iPad 的触控交给虚拟显示器。上面列的 Mac 应用和驱动的权限都要申请。
4. **生成描述文件**：权限批下来后，为 Mac 应用和驱动分别生成包含这些权限的描述文件。
   - 自己用：Development 描述文件，注册上自己这台 Mac。
   - 给别人用：Developer ID 描述文件，签名后还要公证。
5. **改签名方式**：`scripts/build.sh` 现在按方式 A 写，用开发证书强行给应用和驱动加权限。方式 B 要改成用上一步的描述文件签名：在 Xcode 里给 Pivot 和 PivotTouchDriver 两个 target 选好描述文件，或者在 `codesign` 时嵌入对应的描述文件。
6. **安装**：把 `Pivot.app` 放到「应用程序」文件夹后启动，在「驱动程序扩展」里同意驱动。不需要关 SIP 和 AMFI，也不需要 `systemextensionsctl developer on`。

需要说明的几点：

- **审批不保证通过，也没有时限**。HID Virtual Device 需要 Apple 人工审批，开发者论坛上有人等了两个半月仍未获批。
- **方式 B 目前没有实测**。Pivot 是在方式 A 下开发和验证的。方式 B 的步骤按 Apple 对受限权限和系统扩展的规则整理，理论上可行；实际操作时可能还要处理描述文件和签名的细节。欢迎走通后提 PR。
- **付费账号对 iPad 端也有好处**：应用 1 年有效，不用每 7 天重装。远程组网不需要 NetworkExtension 权限，免费和付费账号都能用。

---

## 构建与安装

> 下面是作者自己的构建流程，供参考。在你的设备上编译，大概率要先改签名、Bundle ID、组网配置等写死的部分。

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。iPad 端还要先编译一次内嵌的 EasyTier（需要 rustup 和 `brew install protobuf`，源码放在 `~/data/src/EasyTier`，或者用 `EASYTIER_SRC` 指定）：

```bash
scripts/build-easytier.sh
```

先在 `project.yml` 里填好自己的 `DEVELOPMENT_TEAM` 和 `bundleIdPrefix`，然后：

```bash
xcodegen generate                           # 生成 Xcode 工程；增删源文件后再跑一次
scripts/build.sh mac                        # Mac 端（合成手势）→ build/Build/Products/Debug/Pivot.app
PIVOT_NATIVE_TOUCH=1 scripts/build.sh mac   # Mac 端，带原生触控驱动（方式 A）
scripts/build.sh pad                        # iPad 端
scripts/run-pad.sh <iPad 的设备标识>          # 安装到 iPad 并启动（需插线）
```

首次运行 Mac 端，需要在「系统设置 › 隐私与安全性」里授权：

- **屏幕录制**：采集画面和声音。授权后要重新打开 Pivot。
- **辅助功能**：注入输入、识别输入框。
- **本地网络**：无线连接用。iPad 端首次启动也会询问一次。

## 使用

1. 用 USB‑C 线连接 iPad 和 Mac，在 iPad 上打开 Pivot，几秒内 iPad 就成为一块新屏幕。第一次插线时两端自动配对。
2. 之后不插线也能连：同一网络下，iPad 打开 Pivot，Mac 会自动发现并连接。
3. 远程：Mac 上运行 EasyTier。插线连过一次后，iPad 在任何地方打开 Pivot 都会自动连回这台 Mac。
4. Mac 菜单栏图标里可以：
   - 选显示模式和显示缩放；
   - 看当前线路、触控后端、延迟和帧率；
   - 开关「随航竖屏」；
   - 暂停连接、设置开机启动。
5. iPad 上点画面边上的小圆点，展开悬浮工具条。上面有：
   - 修饰键锁定（⌘ ⌥ ⌃ ⇧）；
   - 显示模式切换；
   - 屏幕键盘；
   - 声音开关；
   - 「仪表盘」菜单，里面是「触控预测」「超分辨率」两个开关。

### 合成手势后端的操作

原生触控生效时，手指操作由 macOS 自己解释。驱动没生效时，合成手势后端按下表处理：

| 操作 | 效果 |
|---|---|
| 单指轻点 / 连点 | 单击 / 双击、三击 |
| 单指在可滚动内容上滑动 | 滚动，带惯性；惯性中按住即停 |
| 单指在标题栏、滑块等处滑动 | 直接拖拽 |
| 长按后移动 | 拖拽（选字、拖文件） |
| 长按后抬起，或双指轻点 | 右键菜单 |
| 双指滑动 / 捏合 / 扭转 | 滚动 / 缩放 / 旋转 |
| 三指左右滑 / 上滑 / 下滑 | 切换桌面 / 调度中心 / 应用窗口 |

## 代码导读

| 想看什么 | 看这里 |
|---|---|
| 虚拟显示器、横竖切换 | `Sources/Mac/VirtualDisplay.swift` |
| 原生触控：虚拟 HID 触摸屏 | `Sources/Mac/Input/HIDTouchscreenInjector.swift` |
| 原生触控：DriverKit 驱动（写 `displayUUID`） | `Driver/PivotTouchDriver.cpp` |
| 驱动的启用与签名 | `Sources/Mac/Input/TouchDriverExtension.swift`、`scripts/build.sh` |
| 随航竖屏、接收随航触点 | `Sources/Mac/SidecarPortrait.swift`、`Sources/Mac/Input/SidecarTouchRecognizer.swift` |
| 合成手势后端 | `Sources/Mac/Input/SyntheticInjector.swift` |
| 采集、编码、自适应码率 | `Sources/Mac/StreamSession.swift`、`Sources/Mac/VideoEncoder.swift` |
| UDP 实时通道（加密、分片、纠错） | `Sources/Shared/Realtime.swift`、`Sources/Mac/RealtimeHost.swift`、`Sources/Pad/RealtimeClient.swift` |
| 内嵌 EasyTier 组网 | `Sources/Pad/MeshLink.swift`、`scripts/build-easytier.sh` |
| iPad 解码、超分辨率 | `Sources/Pad/VideoRenderer.swift` |
| 声音、剪贴板 | `Sources/Mac/AudioStreamer.swift`、`Sources/Pad/AudioPlayer.swift`、`Sources/Mac/ClipboardSync.swift`、`Sources/Pad/PadClipboard.swift` |
| 两端消息协议 | `Sources/Shared/Wire.swift` |

## 实测数据

iPad mini（2316×1512，60Hz）+ M5 Pro MacBook Pro：

| | 有线 | 局域网无线 |
|---|---|---|
| 帧率 | 57–58 fps，零跳帧 | 54–61 fps |
| 延迟（采集到 iPad 送显并回执） | 约 10 毫秒 | 20–45 毫秒 |

## 自测与诊断

```bash
swiftc -O -o build/rt-selftest Sources/Shared/Wire.swift Sources/Shared/Realtime.swift scripts/rt-selftest/main.swift && ./build/rt-selftest
                                               # UDP 实时通道：加密、分片、纠错、丢包回环
build/Build/Products/Debug/Pivot.app/Contents/MacOS/Pivot --gesture-selftest   # 手势与键盘空跑
scripts/wireless-selftest.sh                   # 无线发现、加密、认证的本机回环测试
open --env PIVOT_SELFTEST=stats /Applications/Pivot.app       # 每秒打印帧率、码率、延迟、触控抖动
open --env PIVOT_TRANSPORT=remote /Applications/Pivot.app     # 只接受经 EasyTier 连入，模拟两地
open --env PIVOT_RT=off /Applications/Pivot.app               # 关掉 UDP 实时通道
python3 scripts/muxprobe.py                    # 试连 iPad 上的 Pivot 端口，看 USB 通道是否通
```

Mac 端日志写到标准错误。用 `open --stderr <文件> /Applications/Pivot.app` 启动，可以把日志存到文件。

**代理 TUN 补丁**：Mac 上开着代理软件的 TUN 模式时，EasyTier 的打洞包会被带进代理，NAT 被误判为对称型，只能走中继。`scripts/easytier-bind-if.patch` 让这些套接字绑到真正上网的物理网卡：用 `scripts/build-easytier.sh mac` 编译，`sudo scripts/patch-mac-easytier.sh` 换上（`restore` 还原）。

## 后续计划

- 丢包时用「参考帧失效」或「渐进刷新」代替整张关键帧，网络差时更顺。
- 远程时防止 Mac 睡眠，支持从 iPad 解锁、远程唤醒。
- 推流时可选把 Mac 本机静音。
- 配对密钥存进钥匙串。
- 走通方式 B（付费账号、正式签名），并写进构建脚本。

这是个人项目，计划随作者自己的需要推进，不保证完成。

## 致谢

- [WiredPad](https://github.com/takpika/WiredPad)（MIT）：虚拟触摸屏绑定显示器的关键做法，驱动的手指触控部分移植自它。
- [EasyTier](https://github.com/EasyTier/EasyTier)：内嵌的远程组网。
- Apple TN3212：macOS 上随航触控的接收方式。
