import SwiftUI

@main
struct PocketAcousticAnalystApp: App {
  @State private var appModel = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(appModel)
    }
  }
}
