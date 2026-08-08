# Pocket Acoustic Analyst（声音调查助手）

一款面向非声学专业人士的 iOS 现场声音调查工具。它以“我听到持续嗡声”等实际问题作为入口，引导用户完成测量、解释、空间复测和调整验证。

当前实现聚焦持续低频问题：

- 发现主要低频、可能的倍数频率和强度接近的其他频率；
- 区分稳定、间歇、频率漂移、强弱变化、多个音调和能量分散；
- 在结果页和历史详情中解释出现比例、变化依据、结论边界和复测动作；
- 结合 ARKit 记录房间中的实际测量点；
- 从合格且目标声仍可验证的实测点中找到目标声音较低的位置；
- 比较调整前后，同时拒绝不可比的测量；
- 在同一位置完成三轮 `原状态 → 改变后 → 原状态` 夹测，找出与单一设备状态重复同步的频率线索。

只有稳定且唯一的音调才进入空间扫描。状态调查可跟踪最多四个低频组，但需要 7 次录音、三轮方向一致和两侧基线恢复，结论最高为中等可信度。应用只报告同一设备、同一测量配置下的相对变化。它不是校准声级计，也不会根据频率或同步变化确定声源或房间驻波。单部手机无法完全排除操作期间同时发生的设备负载和环境变化。

## 开发

需要 Xcode 26、[XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0) 或更高版本。应用的最低运行系统是 iOS 17。

```sh
make bootstrap
make build
make test-core
make test
make analyze
make lint
```

`make test` 默认使用 iPhone 16 Pro / iOS 18.6 模拟器。可通过 `SIMULATOR_DESTINATION` 覆盖：

```sh
make test SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
```

连接并信任 iPhone 后，可传入 Xcode 设备 ID 和开发团队运行真机自动化：

```sh
make test-device-core DEVICE_ID='<device-id>' DEVELOPMENT_TEAM='<team-id>'
make test-device-demo-ui DEVICE_ID='<device-id>' DEVELOPMENT_TEAM='<team-id>'
make test-device-audio DEVICE_ID='<device-id>' DEVELOPMENT_TEAM='<team-id>'
make test-device-ar DEVICE_ID='<device-id>' DEVELOPMENT_TEAM='<team-id>'
```

真实麦克风与 AR 用例需要保持设备解锁；AR 用例还需要固定手机并让摄像头朝向有纹理的表面。设备标识和签名团队不会写入仓库。

文档：

- [架构与测量不变量](docs/ARCHITECTURE.md)
- [依赖选型](docs/DEPENDENCIES.md)
- [测试与真机验证](docs/TESTING.md)
- [研究契约、进度与证据](docs/SPRINT.md)
- [从 P0 到产品愿景](docs/ROADMAP.md)

## 隐私

录音只在用户主动测量时采集。分析在设备上完成，只在本地保存分析、状态调查、位置扫描和前后对比结果；不保存原始录音，不包含账号、云上传或遥测。归档会保留用户填写的设备状态、测量时间、输入数据源和相对 AR 位姿；未来若增加导出或上传，必须先使用显式匿名化数据模型。
