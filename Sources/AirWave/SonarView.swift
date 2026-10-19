import SonarCore
import SwiftUI

private let toward = Color(red: 0.31, green: 0.85, blue: 1.0)
private let away = Color(red: 1.0, green: 0.42, blue: 0.66)

/// The menu-bar popover: an on/off switch, the live sonar, and what each gesture does.
struct SonarView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var sonar: SonarEngine

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      SonarScope(sonar: sonar)
      status
      Divider().opacity(0.5)
      VStack(spacing: 8) {
        ForEach(HandGesture.allCases, id: \.self) { gesture in
          GestureRow(gesture: gesture, action: Binding(get: { model.action(for: gesture) }, set: { model.set($0, for: gesture) }), lit: sonar.lastGesture == gesture && sonar.lastGestureAt.timeIntervalSinceNow > -0.8)
        }
      }
      Divider().opacity(0.5)
      HStack {
        Button("Recalibrate") { sonar.recalibrate() }
          .help("Relearn the room's resting echo. Keep your hands still for a second.")
        Spacer()
        Button("Quit AirWave") { NSApp.terminate(nil) }
      }
      .buttonStyle(.borderless)
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 340)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "wave.3.right")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(toward)
      VStack(alignment: .leading, spacing: 0) {
        Text("AirWave").font(.system(size: 15, weight: .bold))
        Text("Sonar gestures").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer()
      Toggle("", isOn: Binding(get: { sonar.isOn }, set: { $0 ? sonar.start() : sonar.stop() }))
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }

  private var status: some View {
    let (icon, text, color): (String, String, Color) = {
      switch sonar.state {
      case .off: return ("pause.circle", "Sonar is off.", .secondary)
      case .starting: return ("hourglass", "Starting…", .secondary)
      case .listening where sonar.noisy: return ("waveform.badge.exclamationmark", "Too noisy right now. Waiting for quiet.", .orange)
      case .listening: return ("checkmark.circle", "Listening. Hold your palm toward the screen about 20 cm away and tap the air.", .green)
      case .cantHearTone: return ("speaker.slash", "Can't hear the tone. Unmute, use the built-in speakers, set volume to about half.", .orange)
      case .noPermission: return ("mic.slash", "Allow the microphone in System Settings → Privacy & Security → Microphone.", .red)
      case .failed(let message): return ("exclamationmark.triangle", message, .red)
      }
    }()
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon).foregroundStyle(color)
      Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Live sonar: echo energy either side of the tone (top) and recent hand motion (bottom).
private struct SonarScope: View {
  @ObservedObject var sonar: SonarEngine

  var body: some View {
    VStack(spacing: 0) {
      Canvas { ctx, size in
        let bands = sonar.bands
        guard bands.count > 2 else { return }
        let mid = bands.count / 2
        let barW = size.width / CGFloat(bands.count)
        // Centre line: the tone itself.
        ctx.fill(Path(CGRect(x: size.width / 2 - 1, y: 6, width: 2, height: size.height - 12)), with: .color(.white.opacity(0.35)))
        for (k, value) in bands.enumerated() where k != mid {
          let h = min(1, CGFloat(value) / 24) * (size.height - 14)
          guard h > 0.5 else { continue }
          let rect = CGRect(x: CGFloat(k) * barW + 1, y: size.height - 7 - h, width: max(1, barW - 2), height: h)
          ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(k > mid ? toward : away))
        }
      }
      .frame(height: 70)
      .overlay(alignment: .bottom) {
        HStack {
          Text("◀ away").foregroundStyle(away)
          Spacer()
          Text("toward ▶").foregroundStyle(toward)
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .opacity(0.8)
      }
      Canvas { ctx, size in
        let trace = sonar.trace
        guard trace.count > 1 else { return }
        let scale = max(sonar.threshold * 4, 200)
        let y = { (v: Float) in size.height / 2 - CGFloat(max(-1, min(1, v / scale))) * (size.height / 2 - 4) }
        // Threshold lines.
        for t in [sonar.threshold, -sonar.threshold] {
          var line = Path()
          line.move(to: CGPoint(x: 0, y: y(t)))
          line.addLine(to: CGPoint(x: size.width, y: y(t)))
          ctx.stroke(line, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
        var path = Path()
        for (k, v) in trace.enumerated() {
          let p = CGPoint(x: size.width * CGFloat(k) / CGFloat(trace.count - 1), y: y(v))
          k == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        ctx.stroke(path, with: .linearGradient(Gradient(colors: [away, .white, toward]), startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: 0)), lineWidth: 2)
      }
      .frame(height: 64)
    }
    .background(
      LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.08, green: 0.11, blue: 0.24)], startPoint: .top, endPoint: .bottom),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
    .opacity(sonar.state == .listening ? 1 : 0.45)
  }
}

private struct GestureRow: View {
  let gesture: HandGesture
  @Binding var action: Action
  let lit: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 26, height: 26)
        .background(lit ? toward.opacity(0.35) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .animation(.easeOut(duration: 0.2), value: lit)
      VStack(alignment: .leading, spacing: 0) {
        Text(gesture.label).font(.system(size: 13, weight: .medium))
        Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary)
      }
      Spacer()
      Picker("", selection: $action) {
        ForEach(Action.allCases) { Text($0.label).tag($0) }
      }
      .labelsHidden()
      .frame(width: 140)
    }
  }

  private var icon: String {
    switch gesture {
    case .tap: "1.circle"
    case .doubleTap: "2.circle"
    case .tripleTap: "3.circle"
    }
  }

  private var hint: String {
    switch gesture {
    case .tap: "Push toward the screen and back, once"
    case .doubleTap: "Twice in a row"
    case .tripleTap: "Three times in a row"
    }
  }
}
