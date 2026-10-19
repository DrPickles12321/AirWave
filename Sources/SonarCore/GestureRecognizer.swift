// Turns the analyzer's stream of signed motion readings into gestures.
//
// There's one motion, an air tap: push your hand toward the screen and bring it back. Gestures are
// how many taps you make in a row (like double-tapping AirPods):
//   tap = one, double tap = two, triple tap = three.
// A "stroke" is a stretch of motion in one direction above the threshold; a tap is a stroke toward
// the screen followed soon after by one away from it. Moving a hand in and leaving it there, or
// pulling it away, isn't a tap, so ordinary movement in front of the laptop is ignored.
// The threshold adapts to the room: it sits a few times above the resting jitter.

public enum HandGesture: String, CaseIterable, Sendable {
  case tap
  case doubleTap
  case tripleTap

  public var label: String {
    switch self {
    case .tap: "Tap"
    case .doubleTap: "Double tap"
    case .tripleTap: "Triple tap"
    }
  }

  public var taps: Int {
    switch self {
    case .tap: 1
    case .doubleTap: 2
    case .tripleTap: 3
    }
  }
}

public final class GestureRecognizer {
  public struct Tuning: Sendable {
    /// The threshold never drops below this, however quiet the room.
    public var minThreshold: Float = 60
    /// The threshold sits this many times above the room's resting jitter.
    public var noiseMultiple: Float = 5
    /// A stroke must last this long (s) to count; shorter flickers are ignored.
    public var minStroke: Double = 0.06
    /// The hand must start back within this long (s) of finishing the push for it to be a tap.
    public var returnGap: Double = 0.5
    /// After a tap, wait this long (s) for another before deciding how many there were.
    public var nextTapWindow: Double = 0.6
    /// Quiet time (s) after a gesture before the next one can start.
    public var cooldown: Double = 0.35
    public init() {}
  }

  public var tuning = Tuning()
  /// Current detection threshold (adapts to the room).
  public private(set) var threshold: Float

  private enum Direction { case toward, away }
  private struct Stroke {
    var direction: Direction
    var start: Double
    var end: Double
  }

  private let dt: Double
  private var time: Double = 0
  private var jitter: Float = 0
  private var smooth: Float = 0
  private var current: Stroke?
  /// A finished push toward the screen, waiting for the hand to come back.
  private var push: Stroke?
  /// Taps so far in this run, and when the last one finished.
  private var taps = 0
  private var lastTap: Double = 0
  private var cooldownUntil: Double = 0

  /// `frameRate`: analysis frames per second (sample rate / hop size).
  public init(frameRate: Double) {
    dt = 1 / frameRate
    threshold = Tuning().minThreshold
  }

  public func reset() {
    current = nil
    push = nil
    taps = 0
    smooth = 0
  }

  /// Feeds one analysis frame; returns any gestures it completes.
  public func feed(velocity: Float, noisy: Bool) -> [HandGesture] {
    time += dt
    var out: [HandGesture] = []
    smooth = smooth * 0.4 + velocity * 0.6
    let v = smooth

    if noisy {
      // Something loud is masking the echo for a moment: skip this frame, but keep any gesture in
      // progress (a click mid-gesture shouldn't cancel it).
    } else if var stroke = current {
      let continuing = stroke.direction == .toward ? v > threshold * 0.35 : v < -threshold * 0.35
      if continuing {
        stroke.end = time
        current = stroke
      } else {
        current = nil
        finish(stroke)
      }
    } else if v > threshold || v < -threshold {
      if time >= cooldownUntil {
        current = Stroke(direction: v > 0 ? .toward : .away, start: time, end: time)
      }
    } else if abs(v) < threshold * 0.5 {
      // Clearly still: learn the room's resting jitter (quickly at first). Frames with some motion
      // in them are left out, or they'd creep the threshold up.
      let rate: Float = time < 2 ? 0.05 : 0.01
      jitter = jitter * (1 - rate) + abs(v) * rate
      threshold = max(tuning.minThreshold, jitter * tuning.noiseMultiple)
    }

    // A push whose hand never came back isn't a tap.
    if let p = push, current == nil, time - p.end > tuning.returnGap {
      push = nil
    }
    // No more taps coming: report how many there were.
    if taps > 0, current == nil, push == nil, time - lastTap > tuning.nextTapWindow {
      let gesture: HandGesture = taps == 1 ? .tap : taps == 2 ? .doubleTap : .tripleTap
      taps = 0
      out.append(gesture)
      cooldownUntil = time + tuning.cooldown
    }
    return out
  }

  private func finish(_ stroke: Stroke) {
    guard stroke.end - stroke.start >= tuning.minStroke else { return }
    switch stroke.direction {
    case .toward:
      push = stroke
    case .away:
      // Toward, then back: one tap.
      if let p = push, stroke.start - p.end < tuning.returnGap {
        push = nil
        taps += 1
        lastTap = time
      }
    }
  }
}
