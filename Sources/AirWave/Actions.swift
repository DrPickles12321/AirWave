import AppKit

/// What a gesture does.
enum Action: String, CaseIterable, Identifiable {
  case none
  case playPause
  case nextTrack
  case previousTrack
  case missionControl

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: "Nothing"
    case .playPause: "Play / Pause"
    case .nextTrack: "Next track"
    case .previousTrack: "Previous track"
    case .missionControl: "Mission Control"
    }
  }

  var symbol: String {
    switch self {
    case .none: "hand.raised"
    case .playPause: "playpause.fill"
    case .nextTrack: "forward.fill"
    case .previousTrack: "backward.fill"
    case .missionControl: "rectangle.3.group"
    }
  }

  func perform() {
    switch self {
    case .none: break
    case .playPause: Media.send(.togglePlayPause)
    case .nextTrack: Media.send(.nextTrack)
    case .previousTrack: Media.send(.previousTrack)
    case .missionControl:
      NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: .init())
    }
  }
}

/// Now-playing controls for whatever app is playing (Music, Spotify, a video in the browser...), via the
/// system's MediaRemote service, which is what the keyboard's media keys use.
enum Media {
  enum Command: Int32 {
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
  }

  private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
  private static let sendCommand: SendCommand? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
          let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
    return unsafeBitCast(symbol, to: SendCommand.self)
  }()

  static func send(_ command: Command) {
    _ = sendCommand?(command.rawValue, nil)
  }
}
