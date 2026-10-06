# Movement Prompt PoC — Project Context
> Read this file at the start of every new session before touching any code.

---

## Environment & Target Setup
- **Xcode**: 27.0
- **iPhone**: iPhone 17 (iOS 26.5.2)
- **Apple Watch**: Series 11 (watchOS 26.6)
- **iOS Target**: `CobainVision`
- **Watch Target**: `watchDetect Watch App`
- **Developer Account**: Free / Personal Team

---

## Research Questions
| # | Question |
|---|----------|
| Q1 | Can Apple's Vision framework (front camera) reliably detect arm and leg gestures? |
| Q2 | Where does it fail — which gestures, camera angles, lighting — especially lower body? |
| Q3 | Does an Apple Watch add value: reject cheating, recover when camera is unsure, HR, haptics? |
| Q4 | Does camera + watch fusion beat camera alone? |

---

## Architecture Decisions
| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pose source | `PoseProvider` protocol | Decouples Vision impl; allows mock / future sources |
| Coordinate system | Vision normalised (origin bottom-left, y increases UP) | All rules written in Vision space |
| Front-camera orientation | `videoOrientation = .portrait` on data output; `orientation: .up` in `VNImageRequestHandler` | Delivers upright portrait frames |
| Overlay x-flip | `screen_x = (1 − vision_x) × width` | Matches the mirrored front camera preview layer |
| Hysteresis | N enter frames / M exit frames, per gesture | Configurable via `AppConfig.swift` |
| Normalisation | Shoulder-to-hip torso length | Invariant to distance; nil if < minTorsoLength |
| Config | `AppConfig.swift` enum | All tuneable thresholds in one single file |
| Log schema | JSON lines per event (prompts, detections, verdicts, watch state) | Structured, human-readable, easy to parse |
| Transport | `WatchConnectivity` (`WCSession`) | Real-time event/feature messaging between iPhone & Watch |
| Background Watch execution | `HKWorkoutSession` + `HKLiveWorkoutBuilder` | Keeps watchOS app running in background during session |
| Detection mode | Dual simultaneous detection + Fusion | cameraOnly, watchOnly, and 4-state fusion rules |

---

## File Map

```
CobainVision/                          <- Xcode project root
├── Config/
│   ├── AppConfig.swift                All tuneable thresholds, frame rates, and script parameters
│   └── DetectionMode.swift            cameraOnly / watchOnly / fusion enum
├── Pose/
│   ├── PoseProvider.swift             Protocol for pose providers
│   ├── PoseFrame.swift                Snapshot of body joints for one frame
│   └── VisionPoseProvider.swift       AVCaptureSession + Vision implementation
├── Gestures/
│   ├── GestureEvent.swift             Event model (type, source, kind, timestamp)
│   ├── GestureDefinitions.swift       5 gestures: rules, required joints, failure modes
│   └── GestureEngine.swift            State machine, hysteresis & framing evaluation
├── Logging/
│   └── SessionLogger.swift            Per-event JSON log recorder & ShareSheet exporter
├── Transport/
│   └── WatchTransport.swift           WCSession wrapper for iPhone/Watch messaging
├── Overlay/
│   └── DebugOverlayView.swift         Skeleton canvas, joint confidence HUD, FPS & gesture status
└── App/
    ├── CobainVisionApp.swift          @main entry point
    └── ContentView.swift              Camera preview, overlay, script runner, live counters & summary UI

watchDetect Watch App/                 <- watchOS app target
├── watchDetectApp.swift               watchOS @main entry point
├── WatchWorkoutManager.swift          HealthKit HKWorkoutSession & CMMotionManager device motion
├── WatchMotionDetector.swift          Forearm pitch & wrist shake detection algorithms
└── WatchContentView.swift             Calibration UI, HR display, wrist side selection & status
```

---

## Current Gesture Definitions & Thresholds
| Gesture | Vision Joints Used | Rule (Vision Space) | Key Threshold | Known Failures |
|---------|-------------------|---------------------|---------------|----------------|
| Right Arm Raise | `.rightShoulder`, `.rightElbow`, `.rightWrist` | `(wrist.y - shoulder.y) / torso > ratio` AND `(elbow.y - shoulder.y) / torso > ratio` | `armRaiseWristAboveShoulderRatio = 0.25`, `armRaiseElbowAboveShoulderRatio = 0.10` | Arm behind head drops elbow; arm crossing body occludes wrist |
| Left Arm Raise | `.leftShoulder`, `.leftElbow`, `.leftWrist` | Same as Right Arm Raise | Same | Same |
| Both-Arm Lateral | All 6 arm joints | `leftArmRaise` AND `rightArmRaise` simultaneously | Same | One arm out of frame -> false; body lean shifts torso length |
| Right High Knee | `.rightHip`, `.rightKnee` | `(knee.y - hip.y) / torso > ratio` | `highKneeKneeAboveHipRatio = 0.15` | Low confidence common; camera at chest height misses knees/ankles |
| Left High Knee | `.leftHip`, `.leftKnee` | Same as Right High Knee | Same | Same |
| Squat | `.leftHip`, `.rightHip`, `.leftAnkle`, `.rightAnkle` | `(hipMidY - ankleMidY) / torso < ratio` | `squatHipAnkleRatio = 1.6` | Most fragile: requires all lower-body joints visible |

---

## Setup & How to Run

### Prerequisites
- Xcode 27.0
- Real iPhone (iOS 26.5.2) + Apple Watch (watchOS 26.6)
- Free or Paid Apple Developer Account (set signing team on targets)

### Running the App
1. Open `CobainVision.xcodeproj` in Xcode.
2. Select target `CobainVision` and destination your paired iPhone.
3. Build and Run (Cmd+R).
4. The watchOS app `watchDetect Watch App` installs automatically on the paired Apple Watch.
5. Grant Camera, HealthKit, and Motion permissions on devices when prompted.

---

## Known Limitations & Risks
- **Simulator limitations**:
  - iPhone Simulator has no camera hardware -> camera pose detection requires physical iPhone.
  - WatchConnectivity messaging and HealthKit workout sessions require real paired Apple Watch hardware for accurate latency & motion testing.
- **Lower-body visibility**:
  - High knee and Squat detection depend heavily on user standing far enough back for knees/ankles to be in frame.
- **Watch arm-gesture scope**:
  - Watch motion detection applies ONLY to arm gestures (right/left arm raise depending on wrist side). Leg and head gestures are camera-only and marked N/A on watch.

---

## Milestone Status
| Milestone | Status |
|-----------|--------|
| M1 — Camera Pose & Gestures | ✅ Completed |
| Milestone W-LITE — Apple Watch + Simple Fusion | ⏳ Step 0 Complete — Awaiting Plan Approval |
