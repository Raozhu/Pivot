# Pivot 远程：流畅度与清晰度优化方案

2026-11-17 整理。目标：远程（两地之间）时跟手、顺滑优先，清晰度其次；竖屏、原生触控、三种显示模式这些交互不变。

## 一、我们现在卡在哪（实测）

| 环节 | 测到的情况 | 影响 |
|---|---|---|
| Mac 的 Wi‑Fi | 到公司路由器本该 3 ms，却每 0.45 秒左右冒一次 50–70 ms 尖峰（p99 61 ms）。临时关掉 AWDL 后 p99 降到 7 ms | 每半秒画面和触控都被卡一下 |
| iPad 那段网络 | 到 iPad：中位数 11 ms，p90 41–92 ms，最大约 200 ms | 同上，而且更严重 |
| 传输方式 | 画面、触控、回执都走同一条 TLS/TCP，再套在 EasyTier 的 UDP 隧道里 | 任何一个包晚到或丢失，后面所有画面和触控都排队等它（队头阻塞） |
| 触控到达 | 滑动时触控包到达时间抖动 34–117 ms，最长间隔 78 ms | Mac 上的滚动一顿一顿，惯性速度算不准 |
| 码率控制 | 每秒看一次「有没有跳帧」，跳了才降码率 | 反应慢，总在出问题之后才调整 |
| iPad 显示 | 收到就显示，没有任何平滑 | 网络一抖，画面节奏就乱 |
| 打洞 | 公司网络只有 IPv4、没有端口映射；5G 是难打的对称型 NAT | 5G 时只能绕道家里的台式机（+20–30 ms） |

已经做过、但效果有限的：降分辨率保 60 帧、远程清晰度整体降一档、编码器不攒帧。原因是瓶颈不在码率，而在「抖动 + TCP 队头阻塞」。

## 二、业界怎么做

### 1. 传输：几乎都用 UDP 自己做，不用 TCP
- **Parsec（BUD 协议）**：基于 UDP，用 DTLS 加密。他们的说法是用 TCP 时丢包会造成很大的延迟；改用 UDP 后丢包只让画质暂时变差，延迟不变。码率根据网络状况实时调整，网络模块和编解码配合设计。[技术页](https://parsec.app/technology) · [协议博客](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007) · [UDP 协议入门](https://parsec.app/blog/a-primer-on-building-udp-networking-protocols-how-we-deliver-low-latency-cloud-gaming-1987806feb62)
- **Moonlight / Sunshine（开源）**：视频走 RTP/UDP，按帧切包，加 Reed‑Solomon 纠错包（`fec_percentage` 默认 20%，局域网可降到 5%）。客户端还会回报纠错情况。[Sunshine 配置](https://docs.lizardbyte.dev/projects/sunshine/master/structconfig_1_1stream__t.html) · [FEC 上限讨论](https://gh.r-mj.com/LizardByte/Sunshine/pull/4926) · [Wolf 的协议说明](https://games-on-whales.github.io/wolf/stable/protocols/index.html)
- **WebRTC 云游戏**：播放延迟设为 0，发送端关掉 pacer，接收端关掉帧缓冲。代价是网络差时帧率不稳。B 站云游戏的经验：长抖动缓冲在无线加公网环境下会多出约 500 ms，不可接受。[讨论](https://groups.google.com/g/discuss-webrtc/c/aLVkzRh9_cc) · [playout-delay 扩展](https://webrtc.googlesource.com/src/+/main/docs/native-code/rtp-hdrext/playout-delay/) · [B 站云游戏](https://besthub.dev/articles/design-and-implementation-of-bilibili-s-low-latency-cloud-gaming-platform-using-webrtc-e4f898bbb3dd)
- **UU 远程**：公开信息只说「高速专网直连」、P2P、智能带宽调节，没有技术细节。评测称 5G 下延迟在 30 ms 以内（推广性质，未独立验证）。[App Store](https://apps.apple.com/cn/app/uu%E8%BF%9C%E7%A8%8B-%E6%B8%B8%E6%88%8F%E4%B8%B2%E6%B5%81-%E8%BF%9C%E7%A8%8B%E5%8A%9E%E5%85%AC/id1642306791) · [评测](https://tech.ifeng.com/c/8xFLAjFzHFR)
- **苹果自家**：Network.framework 支持 QUIC 数据报（`isDatagram`），但开发者论坛有连续发送出错的报告，可靠性要先验证。[WWDC22](https://developer.apple.com/la/videos/play/wwdc2022/10078/?time=381) · [论坛报告](https://developer.apple.com/forums/thread/766220)

### 2. 码率控制：看延迟变化，不等丢包
- **GCC（WebRTC 的拥塞控制）**：接收端测每组包的到达间隔变化，发现排队在变长就先降码率，再结合丢包率做最终决定。基于延迟的控制能把排队压得很低，适合交互场景；靠 TCP 重传的方案一次重传就是约 200 ms 的卡顿。[IETF 草案](https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-01) · [SIGCOMM 论文](https://ccronline.sigcomm.org/wp-content/uploads/2016/07/sigcomm-ccr-paper15.pdf)

### 3. 编码：别让大帧堵路
- **VideoToolbox 低延迟模式**（我们已在用）：不重排帧，一进一出。另外还支持**长期参考帧（LTR）**，用于抗丢包：丢帧后让编码器参考 iPad 确认收到过的旧帧，不用发一个巨大的关键帧。[WWDC21 10158](https://developer.apple.com/videos/play/wwdc2021/10158) · [笔记](https://wwdcnotes.com/documentation/wwdc21-10158-explore-lowlatency-video-encoding-with-videotoolbox/)
- **帧内刷新（Intra Refresh / GDR）**：把关键帧拆散到很多帧里逐步刷新，码率更平稳。但 VideoToolbox 没有公开这个选项，只能当备选。[介绍](https://www.zegocloud.com/blog/intra-refresh) · [AMD 文档](https://docs.amd.com/r/en-US/ug1449-multimedia/GDR-Support)

### 4. 清晰度
- **4:4:4 色度**：Parsec、Jump Desktop、Splashtop 都用它让文字更锐利，代价是码率更高，低带宽时建议关掉。[Parsec](https://support.parsec.app/hc/en-us/articles/32381785123860-Improve-Stream-Quality-and-Color-Accuracy) · [Jump Fluid 2.0](https://changelog.jumpdesktop.com/fluid-2.0-beta-2-studio-quality-remote-desktop-with-4-4-4-and-10-bit-color-1IKhva) · [Fluendo](https://fluendo.com/usecases/true-color-fidelity-enhancement/)

### 5. Mac Wi‑Fi 的 AWDL 抖动
- 隔空投送用的 AWDL 会周期性切信道，造成延迟尖峰，苹果没有正式修复。民间做法：
  - 把路由器的主信道改到 AWDL 常用的信道（5 GHz 上多为 149 或 44）。
  - 把隔空投送设为「接收关闭」。macOS 27.2 上有开发者报告，这样做就算 AWDL 还开着，尖峰也会消失。
  - 用后台工具在需要时临时关掉 AWDL。
  - 注意：手动 `ifconfig awdl0 down` 在睡眠唤醒后会失效。
- 来源：[苹果开发者论坛（27.2）](https://developer.apple.com/forums/thread/847171) · [The Register](https://www.theregister.com/2025/10/23/apple_airdrop_awdl_latency_research/) · [AWDL 延迟分析](https://adamlovattdevops.github.io/awdl-latency-killer/) · [MacRumors](https://forums.macrumors.com/threads/2373916/) · [Meter](https://meter.com/mac-osx-awdl-psa)

## 三、哪些能用到 Pivot 上

| 方案 | 能用吗 | 预期收益 | 代价 |
|---|---|---|---|
| 隔空投送设为「接收关闭」（Mac 和 iPad） | ✅ 不改代码，马上能试 | 可能消掉每半秒的尖峰 | 收不到别人的隔空投送；需要时再打开 |
| 视频和触控改走 UDP，丢帧就跳过 | ✅ 核心改动 | 消除队头阻塞：一个包出问题只影响那一帧，触控永远不排队 | Mac 和 iPad 两端都要改，iPad 要插线装 |
| 纠错包（FEC，10–20%） | ✅ 随 UDP 一起做 | 少量丢包不用重传，也不用请求关键帧 | 多 10–20% 码率 |
| 长期参考帧（LTR）代替关键帧 | ✅ VideoToolbox 原生支持 | 丢帧后几十毫秒恢复，不再发几百 KB 的关键帧 | 实现较细，需要 iPad 回执配合 |
| 每帧大小设上限、分批平滑发送 | ✅ | 大帧不再瞬间塞满 Wi‑Fi 队列 | 运动剧烈时单帧会稍糊 |
| 基于延迟的码率控制（类 GCC） | ✅ | 排队刚出现就降码率，而不是等跳帧 | 需要 iPad 回报每帧到达时间 |
| 触控「去抖动」：Mac 端按原始间隔重放 | ✅ 可做成开关 | 滚动和惯性明显更顺 | 多 10–30 ms 固定延迟 |
| iPad 端可选的小缓冲（按垂直同步显示） | ⚠️ 做成「平滑优先」档 | 画面节奏均匀 | 多一帧左右延迟，默认关 |
| 动起来降分辨率、停下来自动回原画 | ✅ 现有补编逻辑的延伸 | 兼顾跟手和静止时文字清晰 | 每次切换要发一个关键帧，需要防抖 |
| 4:4:4 | ❓ 先验证 iPad 硬件能否解码 HEVC 4:4:4 | 文字更锐利 | 码率增加，远程只建议在带宽充足时开 |
| QUIC 数据报 | ⚠️ 备选 | 自带加密和拥塞控制 | 苹果实现有已知问题，不如自己做 UDP 可控 |
| 本地预测（滑动时先平移旧画面） | ⚠️ 实验性 | 主观「跟手」最强 | 容易出错影，后期再考虑 |
| 帧内刷新 | ❌ VideoToolbox 没公开 | — | — |
| 改走 IPv6 或端口映射直连 | ❌ 公司网络不可控 | — | 在家或换网络时 EasyTier 会自动用上 |

## 四、完整方案（分阶段）

### 第 0 步：先把基础稳住（不改架构）
1. **试隔空投送「接收关闭」**（Mac 和 iPad 都设）：我在 Mac 上复测 ping 尖峰，有效就写进 README 的远程使用建议。
2. **装 iPad 新版**（需要插线一次）。新版已经带了：
   - 换网络自动重连组网（NWPathMonitor），STUN 改用固定 IP；
   - 不再走点对点 Wi‑Fi（不唤醒 AWDL）；
   - 输入框聚焦时自动弹出键盘。
3. **在 iPad 端加统计浮层**：到达抖动、显示帧率、丢帧、端到端延迟。之后每一步都用数据对比。
4. **查清「正在准备画面」后断开的问题**：Mac 端显示画面已推出 2 秒后回执中断，iPad 随后退出组网，需要 iPad 端日志确认（新版会记录）。

### 第 1 步：新传输层「Pivot 实时通道」（收益最大）
- **分工**：
  - TCP（现有 TLS 连接）只留给控制消息：握手、配置、模式切换、键盘、剪贴板。
  - 画面和触控走新的 UDP 通道。远程时经 EasyTier 的 UDP 端口转发；局域网时直接走 UDP。
- **加密**：用配对时已有的预共享密钥派生会话密钥，用 ChaCha20‑Poly1305 加密（CryptoKit 自带），每包带序号防重放。
- **视频**：
  - 每帧切成约 1200 字节的包，包头带帧号、片号、总片数和发送时间戳；
  - 每帧附带 10–20% 的 Reed‑Solomon 纠错包，比例按回报的丢包率在 5–30% 之间自动调；
  - iPad 收齐或靠纠错补齐就立即解码；超过约 1.5 个帧间隔还缺包，就放弃这一帧并通知 Mac；
  - 绝不为了旧帧阻塞新帧。
- **触控**：
  - 每个包除了最新位置，还捎带最近 2–3 个采样（冗余发送），丢一个包不影响轨迹；
  - 只用最新数据，永不排队；
  - 抬起、按下这类关键事件额外重复发 3 次。
- **丢帧恢复**：
  - 先用长期参考帧：iPad 定期确认「我有第 N 帧」，Mac 遇到丢帧时让编码器参考第 N 帧继续编码；
  - 只有确认失败才发关键帧。
- **平滑发送**：一帧的包在约半个帧间隔内均匀发出，不一次性灌进 Wi‑Fi 队列。

### 第 2 步：码率与画质控制
- **类 GCC 的延迟型码率控制**：
  - iPad 每 100 ms 回报一次每组包的到达间隔变化和丢包率；
  - Mac 看到排队延迟上升就降码率（每次 −15%），平稳时缓慢上升（+5%/秒）；
  - 取代现在「跳帧才降」的做法。
- **单帧上限**：用 `DataRateLimits` 限制单帧大小（约平均帧大小的 3 倍），关键帧也一样，避免突发。
- **动静分离**（保清晰度）：
  - 画面在动、或手指在屏幕上时：用当前码率对应的分辨率档，保 60 帧；
  - 静止 0.3 秒后：切回 100% 分辨率，再补编一次高质量帧，静止的文字清晰；
  - 切换加防抖，避免来回跳。
- **4:4:4（可选）**：先验证 iPad 的硬件解码；可行就只在「静止补编」或带宽充足时启用。

### 第 3 步：顺滑度微调
- **触控去抖（Mac 端，可开关）**：按 iPad 原始时间戳的间隔把触控重新排匀再注入；缓冲时长跟随最近抖动（0–30 ms 自适应）。
- **画面节奏（iPad 端，可选）**：「跟手优先」保持现在收到即显示；「平滑优先」按屏幕刷新节拍显示，最多缓冲 1 帧。
- **设置项**：iPad 工具条加「跟手优先 / 平衡 / 画质优先」三档，分别对应缓冲、分辨率档位和纠错比例。

### 第 4 步：网络路径
- 保持 EasyTier 自动选路（直连 › 经家里的台式机 › 中继服务器），开启 `latency_first`。
- 新的 UDP 通道直接跑在 EasyTier 的 UDP 隧道上，不再是 TCP 套 UDP。
- 在家或有 IPv6、端口映射的网络时会自动直连，代码不用改。

## 五、怎么验证
- **网络模拟**：在 Mac 上用 dummynet（`dnctl` + `pfctl`，需要 sudo）注入 1–5% 丢包、30–100 ms 抖动，新旧传输做 A/B 对比。
- **固定指标**：显示帧率、到达抖动 p50/p95、端到端延迟（点按到画面变化）、跳帧数、每分钟卡顿次数（超过 50 ms 没有新帧）。
- **主观测试**：上下滑动长网页、拖动窗口、手写笔，在 5G、家里 Wi‑Fi、公司三种网络下各测一遍。

## 六、工作量与顺序
| 阶段 | 内容 | 估计 | 需要 iPad 插线 |
|---|---|---|---|
| 0 | 隔空投送测试、装新版、统计浮层 | 半天 | 是（装一次） |
| 1 | UDP 实时通道 + 纠错 + 触控冗余 + 长期参考帧 | 2–3 天 | 是 |
| 2 | 延迟型码率控制、单帧上限、动静分离 | 1–2 天 | 是 |
| 3 | 触控去抖、显示节奏、三档设置 | 1 天 | 是 |

第 1 步是关键：它直接针对实测出来的「抖动 + 队头阻塞」，预计会是体感变化最大的一步。

## 七、换 UDP 之外的其他手段

UDP 只解决「排队」这一个环节。卡顿可以从网络、发送端、接收端、交互四个方向下手，下面这些手段可以和它叠加使用，有些甚至不用改传输层。

### A. 让网络本身更稳（不改代码，收益往往最大）
- **Mac 插网线**：用 USB‑C 网卡接公司网口，AWDL 和 Wi‑Fi 抖动一起消失。这是成本最低、最确定的一项。
- **调 Wi‑Fi**：Mac 和 iPad 尽量连 5 GHz。自己能管的路由器（比如家里）把主信道设在 149 或 44，和 AWDL 常用信道重合，切信道造成的尖峰会小很多。
- **隔空投送「接收关闭」**：见第二节第 5 条。
- **离你更近的中转**：同城、带宽够的云服务器做 EasyTier 中继（现在那台只有 3 Mbps），5G 绕路时更快更稳。

### B. 多条网络同时用（iPad 特有）
- **Wi‑Fi 和蜂窝一起发**：iPad 有 5G，可以同一份数据从两条路径各发一遍，谁先到用谁，一条抖了另一条顶上。苹果自己的 Siri 用 MPTCP 的「interactive」模式做类似的事。我们走 UDP 后，可以自己做双路冗余（只给触控和关键帧这类小而重要的包用，省流量）。[MPTCP 在 macOS/iOS](https://mptcp.dev/macOS.html) · [苹果的多路径实践](https://datatracker.ietf.org/meeting/interim-2020-quic-02/materials/slides-interim-2020-quic-02-sessa-multipath-transports-at-apple-00.pdf)

### C. 少传数据、在 iPad 上「补回来」
- **iPad 端超分辨率**：苹果在 iOS 26 / macOS 26 提供低延迟超分（`VTLowLatencySuperResolutionScaler`）。Mac 传 50–65% 分辨率，iPad 用神经网络放大回原尺寸，数据量减半而文字更接近原画。需要实测耗时；首次加载模型较慢，要提前启动。[API](https://developer.apple.com/documentation/videotoolbox/vtlowlatencysuperresolutionscalerconfiguration.md) · [WWDC25](https://nonstrict.eu/wwdcindex/wwdc2025/300/)
- **iPad 端插帧**：同一组 API 里的低延迟插帧（`VTLowLatencyFrameInterpolation`）可以在两帧之间生成中间帧。网络掉帧时用它补上，或者 Mac 只发 30 帧、iPad 显示 60 帧。论坛有直播流里崩溃的报告，属于实验项。[API](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration.md) · [崩溃报告](https://developer.apple.com/forums/thread/817573)

### D. 交互上「藏延迟」
- **触控预测**：iOS 自带 `predictedTouches`，会给出手指接下来一两帧的位置。把预测位置一起发给 Mac，可以抵掉大约一帧的延迟。
- **本地先动（推测渲染）**：滑动时 iPad 先把当前画面按手指位移平移，等 Mac 的真实画面到了再替换。微软的 Outatime 研究用类似的推测思路，在云游戏里掩盖了 120 ms 以上的网络延迟。滚动是最好预测的操作，主观「跟手」提升最明显；难点是边缘出现空白和错位。[Outatime](https://www.microsoft.com/en-us/research/publication/outatime-using-speculation-to-enable-low-latency-continuous-interaction-for-cloud-gaming/)
- **触控去抖**：见第四节第 3 步。

### E. 发送端少制造突发
- **分片编码**：一帧分成几条（slice），编好一条发一条，不必等整帧编完，能省几毫秒。
- **单帧大小上限、平滑发送、长期参考帧代替关键帧**：见第四节。

### 怎么组合
| 组合 | 适合 |
|---|---|
| A（网线 / 隔空投送）+ 第 0 步 | 先把最大的抖动源去掉，马上见效 |
| + UDP 实时通道（第 1 步） | 解决剩下的丢包和排队 |
| + 触控预测 + 本地先动（D） | 网络再好也有往返时间，这一项改变「跟手」的手感 |
| + iPad 超分（C） | 在带宽有限时把清晰度补回来 |
| + 双路冗余（B） | 在外面用 5G 加 Wi‑Fi 时更稳 |
