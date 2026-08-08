# Pocket Acoustic Analyst

一款面向非声学专业人士的 iOS 现场声音调查工具。它以“我听到持续嗡声”等实际问题作为入口，引导用户完成测量、解释、空间复测和调整验证。

当前 P0 聚焦持续低频问题：

- 发现主要低频和可能的谐波；
- 判断音调是否持续、测量是否可靠；
- 结合 ARKit 记录房间中的实际测量点；
- 从合格实测点中推荐相对较安静的位置；
- 比较调整前后，同时拒绝不可比的测量。

应用默认只报告同一设备、同一会话内的相对变化。它不是校准声级计，也不会把频谱特征表述为确定的声源诊断。

## 开发

要求 Xcode 26、iOS 18 SDK 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
make bootstrap
make build
make test
```

架构、验收条件和当前证据记录在 [docs/SPRINT.md](docs/SPRINT.md)。

## 隐私

录音只在用户主动测量时采集。P0 在设备上分析并本地保存结果，不包含账号、云上传或遥测。
