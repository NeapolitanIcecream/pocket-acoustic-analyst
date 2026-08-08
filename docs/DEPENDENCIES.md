# 依赖选型

## 结论

P0 没有第三方运行时依赖。频域运算复用 Apple Accelerate，音频和位置输入复用 AVFoundation 与 ARKit。仓库只用 XcodeGen 生成 Xcode 工程。

| 依赖 | 类型 | 用途 | 选择原因 |
| --- | --- | --- | --- |
| SwiftUI + Observation | 系统框架 | 界面、导航、状态 | iOS 17 可用，与 Swift 6 actor 隔离配合 |
| AVFoundation / AVFAudio | 系统框架 | 权限、测量模式录音、路由和中断 | 直接提供 iOS 硬件生命周期和实际格式 |
| Accelerate / vDSP | 系统框架 | DFT、窗函数和向量运算 | 复用 Apple 优化实现，应用只维护功率标度和领域判定 |
| ARKit | 系统框架 | 相对位置、方向和跟踪质量 | 提供位姿与跟踪失效原因；不自建 SLAM |
| Foundation | 系统框架 | Codable 归档、文件替换、actor | 满足 P0 的本地、小数据量存储 |
| XcodeGen 2.46.0+ | 开发工具 | 由 `project.yml` 生成 `.xcodeproj` | 配置面小，可检视，不进入 App 二进制 |

## 未引入的候选项

### AudioKit

AudioKit 适合通用音频节点和可视化。本项目需要在不同时间、位置和前后测量中保留同一功率标度。对通用 FFT tap 的源码审查发现，默认逐帧归一化不能作为这类相对比较的核心。即使替换该行为，持续性、谐波共现、质量门槛、空间闭环和重采样判定仍需要项目代码。因此 P0 只使用 Accelerate 的成熟数值原语，不引入 AudioKit 依赖树。

### aubio

aubio 的音高和 onset 能力不会替代本项目的窄带功率、持续性、跨测量可比性和 iOS 生命周期处理。引入 C 建置和额外许可边界没有减少 P0 的核心工作，因此未采用。

### Tuist

Tuist 支持更大的多模块工程和缓存工作流。P0 只有一个应用、一个单元测试目标和一个 UI 测试目标，XcodeGen 已满足可重建需求。模块或生成流程变复杂时再重评估。

## 版本和更新策略

- 最低运行系统：iOS 17.0。
- 当前验证工具：Xcode 26.6、Swift 6.3.3、XcodeGen 2.46.0。
- `project.yml` 声明 Swift 6 和完全并发检查。
- 升级 Xcode 或 XcodeGen 后先重生成工程，再执行单元测试、UI 测试、`analyze` 和 `swift-format lint`。
- 新增运行时依赖前，记录精确版本、许可证、更新频率、二进制体积和它取代的现有代码。

## 官方参考

- [SwiftUI Observation 迁移指南](https://developer.apple.com/documentation/SwiftUI/Migrating-from-the-observable-object-protocol-to-the-observable-macro)
- [AVAudioApplication 录音权限](https://developer.apple.com/documentation/avfaudio/avaudioapplication)
- [AVAudioSession 首选采样率](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredsamplerate%28_%3A%29)
- [Accelerate 组合正弦波频率示例](https://developer.apple.com/documentation/accelerate/finding-the-component-frequencies-in-a-composite-sine-wave)
- [Accelerate 窗函数示例](https://developer.apple.com/documentation/accelerate/reducing-spectral-leakage-with-windowing)
- [XcodeGen 2.46.0 发布说明](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)
