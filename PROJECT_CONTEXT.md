# Movement Prompt PoC — Project Context
> Read this file at the start of every new session before touching any code.

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
| Pose source | `PoseProvider` protocol | Decouples Vision impl; allows future sources (ARKit, mock) |
| Coordinate system | Vision normalised (origin bottom-left, y increases UP) | All rules written in Vision space; documented per gesture |
| Front-camera mirror | `videoRotationAngle = 90` on data output; pass `.up` to VNImageRequestHandler | Pixel buffer arrives portrait, unmirrored. Vision `leftXxx` = person's RIGHT side. Gesture rules comment this explicitly. |
| Overlay x-flip | `screen_x = (1 − vision_x) × width` | Matches the mirrored preview layer |
| Hysteresis | N enter frames / M exit frames, per gesture | Single config file |
| Normalisation | Shoulder-to-hip torso length | Invariant to distance; nil if < minTorsoLength |
| Config | `AppConfig.swift` enum | All magic numbers in one place |
| Log schema | Watch sample slots from day one (nil in M1) | No migration needed in M3 |
| Transport | `WatchTransport` protocol (empty in M1) | WatchConnectivity plugged in M3 |
| Detection mode | `DetectionMode` enum | cameraOnly / watchOnly / fusion |
| Third-party deps | None | Per brief |
| Privacy | Camera frames never saved; only joint coords + derived metrics logged | Per brief |

---

## File Map

```
CobainVision/                          <- Xcode target root (PBXFileSystemSynchronizedRootGroup)
├── Config/
│   ├── AppConfig.swift                all tuneable values
│   └── DetectionMode.swift            cameraOnly / watchOnly / fusion enum
├── Pose/
│   ├── PoseProvider.swift             protocol
│   ├── PoseFrame.swift                snapshot of joints for one frame
│   └── VisionPoseProvider.swift       AVCapture + Vision implementation
├── Gestures/
│   ├── GestureEvent.swift             event model (source, kind, timestamp)
│   ├── GestureDefinitions.swift       5 gestures: rules, joints, failure notes
│   └── GestureEngine.swift            state machine + hysteresis + framing check
├── Logging/
│   └── SessionLogger.swift            log schema, CSV writer, watch slots
├── Transport/
│   └── WatchTransport.swift           protocol stub (M1); WatchConnectivity in M3
├── Overlay/
│   └── DebugOverlayView.swift         skeleton, confidences, FPS, gesture states
└── App/
    ├── CobainVisionApp.swift          @main (existing, untouched)
    └── ContentView.swift              camera + overlay + controls

CobainVisionTests/                     <- XCTest target (add manually, see Setup)
├── GestureEngineTests.swift
└── NormalizationTests.swift
```

---

## Gesture Definitions Summary
| Gesture | Vision joints used | Rule (Vision space) | Known failures |
|---------|-------------------|---------------------|----------------|
| Right arm raise | left{Shoulder,Elbow,Wrist} | wristY > shoulderY + ratio*torso | Occluded when arm crosses body |
| Left arm raise | right{Shoulder,Elbow,Wrist} | wristY > shoulderY + ratio*torso | Same |
| Both-arm lateral | all arm joints | both arms pass raise rule simultaneously | Needs full upper body in frame |
| Right high knee | leftHip, leftKnee | kneeY > hipY + ratio*torso | Low confidence common; degrades if feet out of frame |
| Left high knee | rightHip, rightKnee | same, mirrored | Same |
| Squat | hips + knees + ankles | (hipMidY - ankleMidY) / torso < squatRatio | Most fragile: all lower joints needed |

Vision leftXxx = person's RIGHT. rightXxx = person's LEFT. (Front camera raw buffer is unmirrored.)

---

## Setup & How to Run

### Prerequisites
- Xcode 26 (or later)
- Real iPhone running iOS 26+ (Simulator has no camera)
- Your Apple Developer Team ID

### Steps
1. Open `CobainVision.xcodeproj`.
2. Target -> Signing -> set your Team.
3. Add `NSCameraUsageDescription` to the generated Info.plist:
   - Target -> Info tab -> add **Privacy - Camera Usage Description**
   - Value: "Movement Prompt PoC uses the camera to detect body pose. No video is saved."
4. Build & run on a real iPhone (Cmd+R).

### Add the Test Target (one-time)
1. File -> New -> Target -> Unit Testing Bundle, name it `CobainVisionTests`.
2. Add `GestureEngineTests.swift` and `NormalizationTests.swift` to the target.
3. Cmd+U to run (Simulator is fine for unit tests).

### What to test by hand (M1)
- Stand in front of the iPhone propped up at ~arm's length.
- Tap **Start** — the debug skeleton should appear over your body.
- Raise right arm above shoulder -> Right Arm Raise indicator turns green.
- Raise left arm -> Left Arm Raise turns green.
- Raise both arms -> Both Arm Lateral turns green.
- Lift right knee -> Right High Knee (may be unreliable if waist-down out of frame).
- Lift left knee -> Left High Knee.
- Perform a squat (step back so full body is visible) -> Squat.
- FPS should be ~30 on modern iPhones; may be lower on older hardware.

---

## Known Limitations (M1)
- No watch integration (M3).
- No script / test harness (M2).
- No CSV export (M2).
- Squat / high-knee degrades when knees/ankles are outside the frame.
- No calibration for squat threshold — absolute value only in M1.
- Portrait orientation assumed; rotating the device is not handled.

---

## Current Status
| Milestone | Status |
|-----------|--------|
| M1 — Camera only | ✅ Source complete — build and test on device |
| M2 — Test harness | Not started |
| M3 — Watch + fusion | Not started |

---

## Assumptions
| # | Assumption |
|---|-----------|
| A1 | Portrait orientation only (M1). |
| A2 | Front camera only. |
| A3 | Bundle ID `practiceApp.CobainVision` (from existing project). |
| A4 | Vision `.accurate` model by default; configurable in `AppConfig`. |
| A5 | Replay tool will be a separate Swift executable target (M2). |
| A6 | No changes specified when plan was approved; implemented as designed. |

---

## Suggested git commit (M1)
```
feat(M1): camera-only pose detection with Vision + GestureEngine

- PoseProvider protocol + VisionPoseProvider (AVCapture, VNDetectHumanBodyPoseRequest)
- GestureEngine state machine: 5 gestures, hysteresis, torso normalisation
- Debug overlay: skeleton, per-joint confidence colours, FPS, gesture states
- SessionLogger with watch-sample slots (nil in M1)
- WatchTransport protocol stub
- AppConfig: single source of truth for all thresholds
- Unit tests: GestureEngineTests, NormalizationTests
```
