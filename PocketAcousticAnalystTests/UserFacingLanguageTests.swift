import Foundation
import Testing

#if targetEnvironment(simulator)
  @Suite("User-facing language")
  struct UserFacingLanguageTests {
    @Test("Feature copy avoids unexplained instrument terms and unsupported claims")
    func featureCopyUsesProblemLanguage() throws {
      let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let featuresRoot = repositoryRoot.appendingPathComponent("PocketAcousticAnalyst/Features")
      let forbiddenTerms = [
        "FFT",
        "STFT",
        "RTA",
        "SPL",
        "dBA",
        "RT60",
        "驻波节点",
        "已定位声源",
        "安全分贝",
        "专业级",
        "确认结构传声",
      ]

      let enumerator = try #require(
        FileManager.default.enumerator(
          at: featuresRoot,
          includingPropertiesForKeys: nil
        )
      )
      let sourceFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
      #expect(!sourceFiles.isEmpty)
      let stringLiteralPattern = #""(?:\\.|[^"\\])*""#
      let stringLiteralExpression = try NSRegularExpression(pattern: stringLiteralPattern)

      for file in sourceFiles {
        let source = try String(contentsOf: file, encoding: .utf8)
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let userFacingStrings =
          stringLiteralExpression
          .matches(in: source, range: sourceRange)
          .compactMap { Range($0.range, in: source) }
          .map { String(source[$0]) }
          .joined(separator: "\n")
        for term in forbiddenTerms {
          let containsTerm: Bool
          if term.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let pattern =
              "(?i)(?<![A-Za-z])\(NSRegularExpression.escapedPattern(for: term))(?![A-Za-z])"
            let expression = try NSRegularExpression(pattern: pattern)
            containsTerm =
              expression.firstMatch(
                in: userFacingStrings,
                range: NSRange(
                  userFacingStrings.startIndex..<userFacingStrings.endIndex, in: userFacingStrings)
              ) != nil
          } else {
            containsTerm = userFacingStrings.localizedCaseInsensitiveContains(term)
          }
          #expect(
            !containsTerm,
            "\(file.lastPathComponent) contains forbidden user-facing term: \(term)"
          )
        }
      }
    }
  }
#endif
