import Foundation
import SonarCore

// Simulates what the microphone hears (the tone straight from the speakers, a fixed echo off the
// room, an echo off a hand that Doppler-shifts as it moves, background hiss and a burst of typing)
// and checks that the analyzer and recognizer find exactly the gestures the script performs.
// Run with: swift run SonarSelfTest

let sampleRate = 48_000.0
let toneHz = 21_000.0
let hop = 1024
let soundSpeed = 343.0

/// Hand motion: velocity follows half a sine wave (m/s; positive = toward the screen).
struct Motion { var start: Double; var duration: Double; var peak: Double }
var motions: [Motion] = []
var expected: [(gesture: HandGesture, at: Double)] = []

func stroke(_ start: Double, _ duration: Double, _ peak: Double) -> Double {
  motions.append(Motion(start: start, duration: duration, peak: peak))
  return start + duration
}
func tap(_ start: Double) -> Double {
  stroke(stroke(start, 0.14, 0.8), 0.14, -0.8)
}

// The script.
expected.append((.tap, tap(1.5)))
expected.append((.doubleTap, tap(tap(3.5) + 0.12)))
expected.append((.push, stroke(6.0, 0.35, 0.5)))
_ = stroke(7.4, 0.5, -0.35) // hand comes back: not a gesture
expected.append((.pull, stroke(9.5, 0.35, -0.5)))
_ = stroke(10.9, 0.5, 0.35) // hand comes back
// A fast, close push (3 m/s): its echo spreads wide and must not be mistaken for noise.
expected.append((.push, stroke(12.0, 0.25, 3.0)))
_ = stroke(12.9, 0.4, -1.5) // hand comes back
let typingStart = 14.5, typingEnd = 16.1
expected.append((.tap, tap(17.0)))
let duration = 19.0

func handVelocity(_ t: Double) -> Double {
  for m in motions where t >= m.start && t < m.start + m.duration {
    return m.peak * sin(.pi * (t - m.start) / m.duration)
  }
  return 0
}

// Deterministic noise.
var seed: UInt64 = 0x2545F4914F6CDD1D
func uniform() -> Double {
  seed = seed &* 6364136223846793005 &+ 1442695040888963407
  return Double(seed >> 11) / Double(1 << 53)
}
func gaussian() -> Double {
  sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform())
}

// Synthesize.
let count = Int(duration * sampleRate)
var signal = [Float](repeating: 0, count: count)
var handPhase = 0.0, slowPhase = 0.0, fastPhase = 0.0
var nextClick = typingStart
for n in 0..<count {
  let t = Double(n) / sampleRate
  let direct = 0.3 * sin(2 * .pi * toneHz * t)
  let room = 0.01 * sin(2 * .pi * toneHz * t + 1.1)
  let v = handVelocity(t)
  handPhase += 2 * .pi * toneHz * (1 + 2 * v / soundSpeed) / sampleRate
  // Fingers and wrist move a little slower and faster than the palm, smearing the echo.
  slowPhase += 2 * .pi * toneHz * (1 + 2 * 0.6 * v / soundSpeed) / sampleRate
  fastPhase += 2 * .pi * toneHz * (1 + 2 * 1.4 * v / soundSpeed) / sampleRate
  let hand = 0.02 * sin(handPhase) + 0.008 * sin(slowPhase) + 0.008 * sin(fastPhase)
  signal[n] = Float(direct + room + hand + 2e-4 * gaussian())
}
// Typing: short broadband clicks every 80-180 ms.
while nextClick < typingEnd {
  let start = Int(nextClick * sampleRate)
  for k in 0..<240 where start + k < count {
    signal[start + k] += Float(0.25 * exp(-Double(k) / 50) * gaussian())
  }
  nextClick += 0.08 + uniform() * 0.1
}

// Analyze.
let analyzer = DopplerAnalyzer(sampleRate: sampleRate, toneHz: toneHz)
let recognizer = GestureRecognizer(frameRate: sampleRate / Double(hop))
var found: [(gesture: HandGesture, at: Double)] = []
var peakToward: Float = 0, peakAway: Float = 0
var noisyFrames = 0, noisyOutsideTyping = 0, frames = 0
signal.withUnsafeBufferPointer { all in
  var start = 0
  while start + analyzer.size <= count {
    let frame = analyzer.process(UnsafeBufferPointer(rebasing: all[start..<(start + analyzer.size)]))
    let t = Double(start + analyzer.size) / sampleRate
    frames += 1
    peakToward = max(peakToward, frame.velocity)
    peakAway = min(peakAway, frame.velocity)
    if frame.noisy {
      noisyFrames += 1
      if t < typingStart || t > typingEnd + 0.2 { noisyOutsideTyping += 1 }
    }
    for g in recognizer.feed(velocity: frame.velocity, noisy: frame.noisy) { found.append((g, t)) }
    start += hop
  }
}

print("frames: \(frames), peak toward \(Int(peakToward)), peak away \(Int(peakAway)), threshold \(Int(recognizer.threshold))")
print("noisy frames: \(noisyFrames) (\(noisyOutsideTyping) outside the typing burst)")
print("expected: " + expected.map { "\($0.gesture.rawValue)@\(String(format: "%.1f", $0.at))" }.joined(separator: " "))
print("found:    " + found.map { "\($0.gesture.rawValue)@\(String(format: "%.1f", $0.at))" }.joined(separator: " "))

var ok = found.count == expected.count && noisyOutsideTyping == 0
if ok {
  for (e, f) in zip(expected, found) where e.gesture != f.gesture || f.at < e.at || f.at > e.at + 1.5 {
    ok = false
  }
}
print(ok ? "PASS" : "FAIL")
exit(ok ? 0 : 1)
