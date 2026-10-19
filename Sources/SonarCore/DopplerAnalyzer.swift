import Accelerate

// The speakers play a steady tone (about 21 kHz, above most people's hearing) and the microphone
// hears it back, mostly straight from the speakers and partly as echoes off whatever is in front of
// the laptop. A hand moving toward the screen shifts its echo slightly above the tone (the Doppler
// effect); moving away shifts it below. Each frame, this takes an FFT of the latest audio, compares
// the bins just above and below the tone with the room's resting spectrum, and reports how much
// energy has moved up (toward) or down (away).

/// One analysis frame: how the echo around the tone has shifted.
public struct DopplerFrame: Sendable {
  /// Signed motion: positive when something moves toward the laptop, negative when it moves away.
  public var velocity: Float
  public var toward: Float
  public var away: Float
  /// A broadband sound (typing, keys, a clap) is masking the echo, so motion can't be trusted.
  public var noisy: Bool
  /// How far the tone stands above the background (dB). Low means the speakers are muted or too quiet.
  public var toneSNR: Float
  /// Echo energy above the resting spectrum (dB) for each bin from -span to +span around the tone.
  public var bands: [Float]
}

public final class DopplerAnalyzer {
  public let sampleRate: Double
  public let toneHz: Double
  /// FFT length (samples). 4096 at 48 kHz is an 85 ms window with 11.7 Hz bins.
  public let size: Int
  /// Bins either side of the tone that count as echo (24 bins = 280 Hz, about 2.3 m/s of hand speed).
  public let span: Int
  public var binHz: Double { sampleRate / Double(size) }

  /// Bins next to the tone that its own window leakage covers; slower motion than this is ignored.
  private let guardBins = 3
  /// Bins beyond the echo range, used to spot broadband noise.
  private let farBins = 24
  /// How far above the resting level a bin must rise to count (dB).
  private let floorDB: Float = 3
  private let center: Int
  private let setup: vDSP_DFT_Setup
  private let window: [Float]
  private var evens: [Float]
  private var odds: [Float]
  private var outR: [Float]
  private var outI: [Float]
  private var baseline: [Float]
  private var frames = 0
  private let calibrationFrames: Int

  public init(sampleRate: Double, toneHz: Double, size: Int = 4096, span: Int = 24, calibrationFrames: Int = 30) {
    precondition(size.nonzeroBitCount == 1, "FFT size must be a power of two")
    self.sampleRate = sampleRate
    self.toneHz = toneHz
    self.size = size
    self.span = span
    self.calibrationFrames = calibrationFrames
    center = Int((toneHz / (sampleRate / Double(size))).rounded())
    precondition(center + span + farBins < size / 2, "tone too close to the Nyquist limit")
    setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    // Blackman keeps the tone's own leakage to a few bins, so small shifts stand out.
    window = vDSP.window(ofType: Float.self, usingSequence: .blackman, count: size, isHalfWindow: false)
    evens = [Float](repeating: 0, count: size / 2)
    odds = [Float](repeating: 0, count: size / 2)
    outR = [Float](repeating: 0, count: size / 2)
    outI = [Float](repeating: 0, count: size / 2)
    baseline = [Float](repeating: 0, count: 2 * (span + farBins) + 1)
  }

  deinit {
    vDSP_DFT_DestroySetup(setup)
  }

  /// Start learning the room's resting spectrum again (after moving the laptop, say).
  public func recalibrate() {
    frames = 0
  }

  /// Analyses the latest `size` samples, oldest first.
  public func process(_ samples: UnsafeBufferPointer<Float>) -> DopplerFrame {
    precondition(samples.count == size)
    // A real-input DFT takes the even and odd samples as the real and imaginary halves.
    for i in 0..<(size / 2) {
      evens[i] = samples[2 * i] * window[2 * i]
      odds[i] = samples[2 * i + 1] * window[2 * i + 1]
    }
    vDSP_DFT_Execute(setup, evens, odds, &outR, &outI)

    let reach = span + farBins
    var db = [Float](repeating: 0, count: 2 * reach + 1)
    for j in 0..<db.count {
      let k = center - reach + j
      db[j] = 10 * log10f(outR[k] * outR[k] + outI[k] * outI[k] + 1e-12)
    }
    let snr = db[reach] - median(Array(db[0..<farBins]) + Array(db[(db.count - farBins)...]))

    frames += 1
    if frames <= calibrationFrames {
      // Learn what the room sounds like with nothing moving.
      let w = 1 / Float(frames)
      for j in 0..<db.count { baseline[j] += (db[j] - baseline[j]) * w }
      return DopplerFrame(velocity: 0, toward: 0, away: 0, noisy: false, toneSNR: snr, bands: [Float](repeating: 0, count: 2 * span + 1))
    }

    var excess = [Float](repeating: 0, count: db.count)
    for j in 0..<db.count { excess[j] = max(0, db[j] - baseline[j] - floorDB) }

    // Broadband sound lifts the far bins too; an echo only lifts the ones near the tone.
    var far: Float = 0
    for k in (span + 1)...reach { far += excess[reach + k] + excess[reach - k] }
    far /= Float(2 * farBins)
    let noisy = far > 2.5

    // Energy further from the tone means faster motion, so weight by distance.
    var toward: Float = 0
    var away: Float = 0
    for k in guardBins...span {
      let weight = Float(k) / 10
      toward += excess[reach + k] * weight
      away += excess[reach - k] * weight
    }

    // Follow slow changes in the room: quickly while everything is still, barely while moving.
    let still = !noisy && toward + away < 4
    let alpha: Float = still ? 0.05 : 0.002
    for j in 0..<db.count { baseline[j] += (db[j] - baseline[j]) * alpha }

    return DopplerFrame(
      velocity: noisy ? 0 : toward - away,
      toward: toward,
      away: away,
      noisy: noisy,
      toneSNR: snr,
      bands: Array(excess[(reach - span)...(reach + span)])
    )
  }

  private func median(_ values: [Float]) -> Float {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }
}
