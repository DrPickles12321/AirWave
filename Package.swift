// swift-tools-version: 6.0
import PackageDescription

// AirWave: touchless gestures for your Mac, using its own speakers and microphones as a sonar.
// Builds with the Xcode command-line tools alone: `scripts/build-app.sh` makes AirWave.app.
let package = Package(
  name: "AirWave",
  platforms: [.macOS(.v14)],
  targets: [
    // Signal processing and gesture recognition. No audio hardware or UI, so it can be tested offline.
    .target(name: "SonarCore", path: "Sources/SonarCore"),
    // The menu-bar app.
    .executableTarget(name: "AirWave", dependencies: ["SonarCore"], path: "Sources/AirWave"),
    // Feeds SonarCore simulated hand waves and noise, and checks what it recognizes.
    .executableTarget(name: "SonarSelfTest", dependencies: ["SonarCore"], path: "Sources/SonarSelfTest"),
  ],
  swiftLanguageVersions: [.v5]
)
