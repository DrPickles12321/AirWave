import AVFoundation
import QuartzCore
import SonarCore

/// Plays the sonar tone through the speakers, listens with the microphone, and turns the echoes into
/// gestures. Audio is analysed as it arrives and dropped; nothing is recorded.
final class SonarEngine: ObservableObject {
  enum State: Equatable {
    case off
    case starting
    case listening
    /// The mic can't hear the tone: sound muted, volume too low, or headphones in.
    case cantHearTone
    case noPermission
    case failed(String)
  }

  @Published private(set) var state: State = .off
  /// Echo energy above the resting level, bin by bin around the tone (for the visualizer).
  @Published private(set) var bands: [Float] = []
  /// Recent motion readings, oldest first.
  @Published private(set) var trace: [Float] = Array(repeating: 0, count: 180)
  @Published private(set) var threshold: Float = 60
  @Published private(set) var noisy = false
  @Published private(set) var lastGesture: HandGesture?
  @Published private(set) var lastGestureAt = Date.distantPast

  var onGesture: ((HandGesture) -> Void)?
  let toneHz = 21_000.0

  private let engine = AVAudioEngine()
  private var tone: AVAudioSourceNode?
  private let dsp = DispatchQueue(label: "app.airwave.dsp", qos: .userInteractive)
  private let hop = 1024
  // Owned by the dsp queue.
  private var analyzer: DopplerAnalyzer?
  private var recognizer: GestureRecognizer?
  private var window: [Float] = []
  private var pending: [Float] = []
  private var history: [Float] = Array(repeating: 0, count: 180)
  private var lastPublish: CFTimeInterval = 0
  private var quietToneFrames = 0
  /// Tone loudness the render thread fades toward (so starting and stopping never clicks).
  private var toneTarget: Float = 0
  private var configObserver: NSObjectProtocol?
  /// Optional diagnostics: one line of numbers per analysis frame (no audio). Turn on with
  /// `defaults write app.airwave.AirWave debugLog -bool true`; written to /tmp/airwave-debug.log.
  private var debugLog: FileHandle?
  private var debugStart: CFTimeInterval = 0

  var isOn: Bool { state != .off && state != .noPermission }

  func start() {
    guard state == .off || state == .noPermission || { if case .failed = state { return true }; return false }() else { return }
    state = .starting
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      begin()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { granted ? self.begin() : (self.state = .noPermission) }
      }
    default:
      state = .noPermission
    }
  }

  func stop() {
    guard isOn else { return }
    toneTarget = 0
    // Let the tone fade out before stopping.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      self.teardown()
      self.state = .off
    }
  }

  /// Relearn the room's resting echo (after moving the laptop, say).
  func recalibrate() {
    dsp.async {
      self.analyzer?.recalibrate()
      self.recognizer?.reset()
    }
  }

  private func begin() {
    let input = engine.inputNode
    let inFormat = input.inputFormat(forBus: 0)
    guard inFormat.sampleRate >= 44_100 else {
      state = .failed("No microphone that can hear high frequencies")
      return
    }
    let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard outRate >= 44_100, let toneFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 1) else {
      state = .failed("Speakers can't play the sonar tone")
      return
    }

    // The tone: a plain sine wave, faded in and out.
    let step = 2 * Double.pi * toneHz / outRate
    var phase = 0.0
    var level: Float = 0
    // Diagnostics: `defaults write app.airwave.AirWave debugMuteTone -bool true` keeps the tone silent.
    toneTarget = UserDefaults.standard.bool(forKey: "debugMuteTone") ? 0 : 0.25
    let source = AVAudioSourceNode(format: toneFormat) { [unowned self] _, _, frameCount, buffers -> OSStatus in
      let list = UnsafeMutableAudioBufferListPointer(buffers)
      let target = self.toneTarget
      for f in 0..<Int(frameCount) {
        level += (target - level) * 0.0008
        let sample = Float(sin(phase)) * level
        phase += step
        if phase > 2 * .pi { phase -= 2 * .pi }
        for buffer in list { buffer.mData?.assumingMemoryBound(to: Float.self)[f] = sample }
      }
      return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: toneFormat)
    tone = source

    let rate = inFormat.sampleRate
    if UserDefaults.standard.bool(forKey: "debugLog") {
      let path = "/tmp/airwave-debug.log"
      FileManager.default.createFile(atPath: path, contents: nil)
      debugLog = FileHandle(forWritingAtPath: path)
      debugStart = CACurrentMediaTime()
      debugLog?.write("# input \(Int(rate)) Hz, \(inFormat.channelCount) ch, output \(Int(outRate)) Hz, tone \(Int(toneHz)) Hz\n# t velocity toward away snr noisy threshold peakBand peakDB noiseDB gestures\n".data(using: .utf8)!)
    }
    dsp.sync {
      let a = DopplerAnalyzer(sampleRate: rate, toneHz: toneHz)
      analyzer = a
      recognizer = GestureRecognizer(frameRate: rate / Double(hop))
      window = [Float](repeating: 0, count: a.size)
      pending = []
      quietToneFrames = 0
    }
    var expectedSampleTime: AVAudioFramePosition = -1
    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hop), format: inFormat) { [weak self] buffer, when in
      guard let self, let channel = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      let samples = Array(UnsafeBufferPointer(start: channel, count: count))
      if self.debugLog != nil {
        // Buffer timing: a gap or overlap in sample time means the stream skipped or repeated audio.
        let start = when.sampleTime
        let gap = expectedSampleTime < 0 ? 0 : start - expectedSampleTime
        expectedSampleTime = start + AVAudioFramePosition(count)
        // Biggest sample-to-sample jump, relative to what a pure tone allows.
        var jump: Float = 0
        var at = 0
        for i in 1..<count where abs(samples[i] - samples[i - 1]) > jump {
          jump = abs(samples[i] - samples[i - 1])
          at = i
        }
        let peak = samples.map(abs).max() ?? 0
        let note = String(format: "# buffer n=%d gap=%lld jump=%.4f at=%d peak=%.4f\n", count, gap, jump, at, peak)
        self.dsp.async { self.debugLog?.write(note.data(using: .utf8)!) }
      }
      self.dsp.async { self.ingest(samples) }
    }

    do {
      engine.prepare()
      try engine.start()
      state = .listening
    } catch {
      teardown()
      state = .failed(error.localizedDescription)
      return
    }
    // Switching audio devices (headphones, displays) stops the engine; start again on the new ones.
    configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      guard let self, self.isOn else { return }
      self.teardown()
      self.state = .off
      self.start()
    }
  }

  private func teardown() {
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    configObserver = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if let tone {
      engine.detach(tone)
      self.tone = nil
    }
  }

  // MARK: - Analysis (dsp queue)

  private func ingest(_ samples: [Float]) {
    guard let analyzer, let recognizer else { return }
    pending.append(contentsOf: samples)
    while pending.count >= hop {
      // Slide the analysis window along by one hop.
      window.removeFirst(hop)
      window.append(contentsOf: pending.prefix(hop))
      pending.removeFirst(hop)
      let frame = window.withUnsafeBufferPointer { analyzer.process($0) }
      let gestures = recognizer.feed(velocity: frame.velocity, noisy: frame.noisy)
      history.removeFirst()
      history.append(frame.velocity)
      // The tone should stand far above the background; if not, the mic can't hear it.
      quietToneFrames = frame.toneSNR < 25 ? quietToneFrames + 1 : 0
      if let debugLog {
        let mid = frame.bands.count / 2
        let peak = frame.bands.indices.max(by: { frame.bands[$0] < frame.bands[$1] }) ?? mid
        let line = String(format: "%.3f %.0f %.0f %.0f %.1f %d %.0f %d %.1f %.1f %@\n",
                          CACurrentMediaTime() - debugStart, frame.velocity, frame.toward, frame.away, frame.toneSNR,
                          frame.noisy ? 1 : 0, recognizer.threshold, peak - mid, frame.bands.isEmpty ? 0 : frame.bands[peak], frame.noiseLevel,
                          gestures.map(\.rawValue).joined(separator: ","))
        debugLog.write(line.data(using: .utf8)!)
      }
      publish(frame, gestures, threshold: recognizer.threshold)
    }
  }

  private func publish(_ frame: DopplerFrame, _ gestures: [HandGesture], threshold: Float) {
    let now = CACurrentMediaTime()
    guard !gestures.isEmpty || now - lastPublish > 1.0 / 30 else { return }
    lastPublish = now
    let trace = history
    let cantHear = quietToneFrames > 40
    DispatchQueue.main.async {
      self.bands = frame.bands
      self.trace = trace
      self.threshold = threshold
      self.noisy = frame.noisy
      if self.state == .listening || self.state == .cantHearTone {
        self.state = cantHear ? .cantHearTone : .listening
      }
      for gesture in gestures {
        self.lastGesture = gesture
        self.lastGestureAt = Date()
        self.onGesture?(gesture)
      }
    }
  }
}
