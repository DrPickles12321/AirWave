import AVFoundation
import AudioToolbox
import CoreAudio

/// Finds the Mac's own microphone and speakers. AirWave always uses these, whatever the system's
/// current input and output are: AirPods or other Bluetooth headsets can't play or hear a 21 kHz
/// tone, and this way music can keep playing in headphones while the laptop runs the sonar.
enum BuiltInAudio {
  static var speakers: AudioDeviceID? { device(scope: kAudioObjectPropertyScopeOutput) }

  /// The built-in microphone as a capture device (capture lets us pick it explicitly).
  static var captureMicrophone: AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
      .first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
  }

  /// Points an input or output unit at a specific device. Returns false if Core Audio refused.
  @discardableResult
  static func use(_ device: AudioDeviceID, for unit: AudioUnit) -> Bool {
    var id = device
    return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
  }

  private static func device(scope: AudioObjectPropertyScope) -> AudioDeviceID? {
    allDevices().first { isBuiltIn($0) && hasStreams($0, scope: scope) }
  }

  private static func allDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr && transport == kAudioDeviceTransportTypeBuiltIn
  }

  private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
  }
}

/// Reads a specific microphone as 48 kHz mono float samples, independent of the system's current input.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  let sampleRate: Double = 48_000
  var onSamples: (([Float]) -> Void)?
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()

  func start(device: AVCaptureDevice, queue: DispatchQueue) throws {
    stop()
    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()
    guard session.canAddInput(input), session.canAddOutput(output) else {
      session.commitConfiguration()
      throw NSError(domain: "AirWave", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't open the built-in microphone"])
    }
    session.addInput(input)
    session.addOutput(output)
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: true,
    ]
    output.setSampleBufferDelegate(self, queue: queue)
    session.commitConfiguration()
    session.startRunning()
  }

  func stop() {
    if session.isRunning { session.stopRunning() }
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    for output in session.outputs { session.removeOutput(output) }
    session.commitConfiguration()
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let length = CMBlockBufferGetDataLength(block)
    var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
    let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
    if status == kCMBlockBufferNoErr { onSamples?(samples) }
  }
}
