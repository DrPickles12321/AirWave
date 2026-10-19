import SonarCore
import SwiftUI

@main
struct AirWaveApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      SonarView(model: model, sonar: model.sonar)
    } label: {
      MenuBarIcon(sonar: model.sonar)
    }
    .menuBarExtraStyle(.window)
  }
}

/// Owns the sonar, remembers what each gesture does, and carries gestures out.
final class AppModel: ObservableObject {
  let sonar = SonarEngine()
  private let hud = GestureHUD()
  @Published private var mapping: [HandGesture: Action] = [:]

  private static let defaults: [HandGesture: Action] = [.tap: .playPause, .doubleTap: .nextTrack, .tripleTap: .previousTrack]

  init() {
    for gesture in HandGesture.allCases {
      let saved = UserDefaults.standard.string(forKey: key(gesture)).flatMap(Action.init(rawValue:))
      mapping[gesture] = saved ?? Self.defaults[gesture] ?? Action.none
    }
    sonar.onGesture = { [weak self] gesture in self?.handle(gesture) }
    // Start listening as soon as the app launches (asks for the microphone the first time).
    DispatchQueue.main.async { self.sonar.start() }
  }

  func action(for gesture: HandGesture) -> Action {
    mapping[gesture] ?? Action.none
  }

  func set(_ action: Action, for gesture: HandGesture) {
    mapping[gesture] = action
    UserDefaults.standard.set(action.rawValue, forKey: key(gesture))
  }

  private func handle(_ gesture: HandGesture) {
    let action = action(for: gesture)
    action.perform()
    hud.show(gesture, action)
  }

  private func key(_ gesture: HandGesture) -> String {
    "gesture.\(gesture.rawValue)"
  }
}

/// The menu-bar icon: waves when listening, a slash when off; it flashes when a gesture lands.
private struct MenuBarIcon: View {
  @ObservedObject var sonar: SonarEngine

  var body: some View {
    let recent = sonar.lastGestureAt.timeIntervalSinceNow > -0.6
    Image(systemName: sonar.state == .listening ? (recent ? "wave.3.right.circle.fill" : "wave.3.right") : "wave.3.right.circle")
  }
}
