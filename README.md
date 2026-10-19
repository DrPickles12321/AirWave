# AirWave

**Touchless gestures for your Mac, using its own speakers and microphones as a sonar.** No camera, no extra hardware.

AirWave plays a steady 21 kHz tone (above the range most people can hear) through the built-in speakers and listens to it with the built-in microphone. Your hand reflects some of that sound back. When the hand moves toward the screen, its echo comes back slightly higher in pitch; when it moves away, slightly lower (the Doppler effect). AirWave measures that shift about 47 times a second and turns it into gestures:

| Gesture | Motion | Default action |
|---|---|---|
| Tap | Push your palm toward the screen and back | Play / pause |
| Double tap | Twice in a row | Next track |
| Triple tap | Three times in a row | Previous track |

One motion, counted (like double-tapping AirPods), so gestures can't be confused with each other, and moving a hand in front of the laptop without bringing it back does nothing.

It lives in the menu bar, with a live view of the sonar and a picker for what each gesture does. Media actions work with whatever is playing (Music, Spotify, a video in the browser).

## How it works

```
speakers ──► 21 kHz tone ──► bounces off your hand
                                    │
microphone ◄────────────────────────┘
    │
    ▼  every 21 ms
FFT of the last 85 ms ──► energy just above / below 21 kHz, compared with the room's resting echo
    ──► signed motion (toward / away) ──► strokes ──► taps ──► tap · double tap · triple tap
```

- `Sources/SonarCore/DopplerAnalyzer.swift`: Blackman-windowed FFT (Accelerate/vDSP), resting-spectrum baseline, weighted Doppler sidebands, and broadband-noise rejection (typing and clinking keys light up frequencies far from the tone; a moving hand doesn't).
- `Sources/SonarCore/GestureRecognizer.swift`: an adaptive threshold above the room's jitter, strokes with hysteresis, and a small state machine that pairs a stroke toward the screen with one back (a tap) and counts taps in a row.
- `Sources/SonarSelfTest/main.swift`: synthesizes the microphone signal (direct tone, room echo, a Doppler-shifted hand echo, hiss, a burst of typing) and checks the exact gestures come out (including a fast, close tap whose echo smears wide, and a hand that moves in and stays, which must not count).
- `Sources/AirWave/`: the menu-bar app (AVAudioEngine for the tone and microphone, SwiftUI for the UI).

Audio is analysed in memory as it arrives and is never recorded or sent anywhere.

## Build

Needs only the Xcode command-line tools (not full Xcode):

```bash
scripts/build.sh run        # build build/AirWave.app and open it
scripts/build.sh selftest   # run the offline sonar self-test
```

Use the built-in speakers at about half volume and keep your hand 10 to 30 cm from the screen.
