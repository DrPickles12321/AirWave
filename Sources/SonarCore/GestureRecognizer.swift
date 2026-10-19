// Turns the analyzer's stream of signed motion readings into gestures.
//
// A "stroke" is a stretch of motion in one direction above the threshold. Then:
//   tap        = a stroke toward the screen, quickly followed by one away (an air tap)
//   double tap = two taps close together
//   push       = a stroke toward the screen with nothing straight after it
//   pull       = a stroke away from the screen with nothing straight after it
// After a push or a pull, moving your hand back to where it started isn't counted as a gesture.
// The threshold adapts to the room: it sits a few times above the resting jitter.

public enum HandGesture: String, CaseIterable, Sendable {
  case tap
  case doubleTap
  case push
  case pull

  public var label: String {
    switch self {
    case .tap: "Tap"
    case .doubleTap: "Double tap"
    case .push: "Push"
    case .pull: "Pull"
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
    /// A push or pull must average at least this many times the threshold over `pushTime` (s) or
    /// more, so a flicker of room noise never counts (taps are recognized by their shape instead).
    public var deliberate: Float = 1.0
    public var pushTime: Double = 0.12
    /// The away half of a tap must start within this long (s) of the toward half ending.
    public var tapGap: Double = 0.3
    /// A second tap within this long (s) of the first makes a double tap.
    public var doubleTapWindow: Double = 0.6
    /// After a push or pull, a stroke back the other way within this long (s) is just the hand returning.
    public var returnWindow: Double = 2.0
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
    var peak: Float
    var total: Float = 0
    var frames = 0
    var mean: Float { frames > 0 ? total / Float(frames) : 0 }
  }

  private let dt: Double
  private var time: Double = 0
  private var jitter: Float = 0
  private var smooth: Float = 0
  private var current: Stroke?
  /// A finished stroke waiting to see whether it's the first half of a tap.
  private var held: Stroke?
  /// When a tap finished, while we wait to see if a second one follows.
  private var pendingTap: Double?
  /// After a push or pull: the direction (and deadline) of the hand coming back.
  private var expectReturn: (direction: Direction, until: Double)?
  private var cooldownUntil: Double = 0

  /// `frameRate`: analysis frames per second (sample rate / hop size).
  public init(frameRate: Double) {
    dt = 1 / frameRate
    threshold = Tuning().minThreshold
  }

  public func reset() {
    current = nil
    held = nil
    pendingTap = nil
    expectReturn = nil
    smooth = 0
  }

  /// Feeds one analysis frame; returns any gestures it completes.
  public func feed(velocity: Float, noisy: Bool) -> [HandGesture] {
    time += dt
    var out: [HandGesture] = []
    smooth = smooth * 0.4 + velocity * 0.6
    let v = smooth

    if noisy {
      // Something loud is masking the echo: drop anything half-recognized.
      current = nil
      held = nil
    } else if var stroke = current {
      let continuing = stroke.direction == .toward ? v > threshold * 0.35 : v < -threshold * 0.35
      if continuing {
        stroke.end = time
        stroke.peak = max(stroke.peak, abs(v))
        stroke.total += abs(v)
        stroke.frames += 1
        current = stroke
      } else {
        current = nil
        finish(stroke, &out)
      }
    } else if v > threshold || v < -threshold {
      if time >= cooldownUntil {
        current = Stroke(direction: v > 0 ? .toward : .away, start: time, end: time, peak: abs(v), total: abs(v), frames: 1)
      }
    } else if abs(v) < threshold * 0.5 {
      // Clearly still: learn the room's resting jitter (quickly at first). Frames with some motion
      // in them are left out, or they'd creep the threshold up.
      let rate: Float = time < 2 ? 0.05 : 0.01
      jitter = jitter * (1 - rate) + abs(v) * rate
      threshold = max(tuning.minThreshold, jitter * tuning.noiseMultiple)
    }

    // A stroke with nothing straight after it is a push or a pull.
    if let h = held, current == nil, time - h.end > tuning.tapGap {
      held = nil
      standalone(h, &out)
    }
    // A tap with no second tap after it (not while a possible second tap is still under way).
    if let p = pendingTap, current == nil, held == nil, time - p > tuning.doubleTapWindow {
      pendingTap = nil
      emit(.tap, &out)
    }
    return out
  }

  private func finish(_ stroke: Stroke, _ out: inout [HandGesture]) {
    guard stroke.end - stroke.start >= tuning.minStroke else { return }
    // The hand coming back after a push or pull.
    if let r = expectReturn, stroke.direction == r.direction, stroke.start < r.until {
      expectReturn = nil
      return
    }
    expectReturn = nil
    // Toward, then quickly away: a tap.
    if stroke.direction == .away, let h = held, h.direction == .toward, stroke.start - h.end < tuning.tapGap {
      held = nil
      if let p = pendingTap, time - p < tuning.doubleTapWindow + tuning.tapGap * 2 {
        pendingTap = nil
        emit(.doubleTap, &out)
      } else {
        pendingTap = time
      }
      return
    }
    if let h = held {
      // The earlier stroke didn't turn into a tap, so it stands on its own.
      standalone(h, &out)
    }
    held = stroke
  }

  /// A stroke on its own is a push or a pull, if it was strong enough to be on purpose.
  private func standalone(_ stroke: Stroke, _ out: inout [HandGesture]) {
    guard stroke.mean >= threshold * tuning.deliberate, stroke.end - stroke.start >= tuning.pushTime else { return }
    emit(stroke.direction == .toward ? .push : .pull, &out)
    expectReturn = (stroke.direction == .toward ? .away : .toward, time + tuning.returnWindow)
  }

  private func emit(_ gesture: HandGesture, _ out: inout [HandGesture]) {
    out.append(gesture)
    cooldownUntil = time + tuning.cooldown
  }
}
