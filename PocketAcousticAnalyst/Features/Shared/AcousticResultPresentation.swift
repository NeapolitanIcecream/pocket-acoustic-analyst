import Foundation

struct AcousticResultPresentation: Equatable, Sendable {
  var title: String
  var subtitle: String
  var evidence: String
  var limitation: String
  var action: String
}

extension AcousticAnalysis {
  var resolvedSoundPattern: LowFrequencySoundPattern {
    if let soundPattern { return soundPattern }
    guard let tone else { return .distributedEnergy }
    if !tone.competingToneFrequenciesHz.isEmpty { return .multipleTones }
    if tone.frequencySpreadHz > configuration.stableFrequencySpreadHz { return .driftingTone }
    if tone.levelSpreadDB > configuration.stableLevelSpreadDB { return .varyingLevelTone }
    if tone.persistence < configuration.minimumTonePersistence { return .intermittentTone }
    return .stableTone
  }

  var resultPresentation: AcousticResultPresentation {
    let evidenceTone = bestToneEvidence
    let frequency = evidenceTone.map { wholeFrequency($0.frequencyHz) } ?? ""

    switch resolvedSoundPattern {
    case .stableTone:
      return AcousticResultPresentation(
        title: "检测到持续低频声音",
        subtitle: "主要集中在约 \(frequency)",
        evidence: "这个低频在大多数测量时段都出现，频率和强弱变化在本次可用范围内。",
        limitation: "仅凭这次录音不能确定是哪台设备，也不能确认房间驻波或传播路径。",
        action: "这个声音适合继续比较房间里的不同实测位置。"
      )

    case .intermittentTone:
      let persistence = evidenceTone.map { Int(($0.persistence * 100).rounded()) } ?? 0
      let title = persistence < 25 ? "检测到短暂出现的低频音调" : "检测到间歇出现的低频音调"
      return AcousticResultPresentation(
        title: title,
        subtitle: "候选频率约 \(frequency)，在约 \(persistence)% 的时段出现",
        evidence: "这个频率没有贯穿本次测量，可能对应设备启停、转速变化或短暂干扰。",
        limitation: "目标没有持续出现，当前不能把不同时间或位置的读数直接归因于空间差异。",
        action: "保持手机位置不变并连续重测，同时记录设备开关或负载变化。"
      )

    case .driftingTone:
      let range = frequencyRange(evidenceTone)
      return AcousticResultPresentation(
        title: "检测到频率变化的低频音调",
        subtitle: range.map { "主要在约 \($0) 之间变化" } ?? "主要频率随时间变化",
        evidence: "多数时段都能找到音调，但它的主要频率变化超过了稳定音调门槛。",
        limitation: "频率仍在变化，当前不能锁定一个固定频带进行房间位置比较。",
        action: "保持手机不动并延长观察，记录空调模式、风扇转速或设备负载是否同步变化。"
      )

    case .varyingLevelTone:
      let spread =
        evidenceTone?.levelSpreadDB.formatted(
          .number.precision(.fractionLength(1))) ?? "未知"
      return AcousticResultPresentation(
        title: "检测到强弱变化明显的低频音调",
        subtitle: "主要频率约 \(frequency)",
        evidence: "音调在多数时段都出现，但时段间强弱离散约为 \(spread) dB。",
        limitation: "声源或环境在本次测量中变化较大，当前不能可靠比较房间位置。",
        action: "保持手机位置不变并连续重测，观察强弱变化是否按固定周期重复。"
      )

    case .multipleTones:
      let frequencies =
        ([evidenceTone?.frequencyHz].compactMap { $0 }
        + (evidenceTone?.competingToneFrequenciesHz ?? []))
        .prefix(4)
        .map(wholeFrequency)
        .joined(separator: "、")
      return AcousticResultPresentation(
        title: "检测到多个低频音调",
        subtitle: frequencies.isEmpty ? "没有唯一的主要频率" : "主要包括约 \(frequencies)",
        evidence: "至少两个频率的强度接近，可能来自多个设备或同一设备的不同周期成分。",
        limitation: "当前不能把其中一个频率当作唯一问题，也不能据此确定声源。",
        action: "保持手机位置不变，每次只改变一台设备的运行状态后复测。"
      )

    case .distributedEnergy:
      return AcousticResultPresentation(
        title: "低频能量没有集中在单一频率",
        subtitle: "这次没有可锁定的持续音调",
        evidence: "在 10–500 Hz 范围内，没有形成足够突出且可重复的单一频率。",
        limitation: "这不代表环境安静，也不代表没有低频声音；风噪和多个变化声源可能呈现这种结果。",
        action: "在声音最明显时重测，或使用较长观察来记录设备启停和频率变化。"
      )
    }
  }

  private func wholeFrequency(_ value: Double) -> String {
    "\(Int(value.rounded())) Hz"
  }

  private func frequencyRange(_ tone: ToneAnalysis?) -> String? {
    let frequencies = tone?.frameTrace.compactMap(\.frequencyHz) ?? []
    guard let minimum = frequencies.min(), let maximum = frequencies.max() else { return nil }
    return "\(Int(minimum.rounded()))–\(Int(maximum.rounded())) Hz"
  }
}
