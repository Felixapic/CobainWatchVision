# Movement Prompt PoC — Project Context
> Read this file at the start of every new session before touching any code.

---

## Environment & Target Setup
- **Xcode**: 27.0
- **Mac**: macOS Desktop App Target (`CobainVisionMac`)
- **iPhone**: iPhone 17 (iOS 26.5.2) — Thigh Sensor & Watch Relay Hub Target (`CobainVision`)
- **Apple Watch**: Series 11 (watchOS 26.6) — Arm Sensor Target (`watchDetect Watch App`)
- **Developer Account**: Free / Personal Team

---

## Research Questions
| # | Question |
|---|----------|
| Q1 | Can Apple's Vision framework (front camera / Mac webcam / Continuity Camera) reliably detect arm and leg gestures? |
| Q2 | Where does it fail — which gestures, camera angles, lighting — especially lower body? |
| Q3 | Does multi-sensor fusion (Watch arm pitch + iPhone thigh angle + Mac Vision) eliminate lower-body occlusion and cheat gestures? |
| Q4 | Does camera + watch + thigh fusion beat camera alone? |

---

## Architecture Decisions (Milestone H-A Research Rig)
| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture Rig | Mac Dashboard + iPhone Thigh Hub + Watch Sensor | Multi-sensor hub pipeline. Video stays strictly on Mac. |
| Pose source | Mac-side Vision Framework (`VisionPoseProvider`) | Webcam / Continuity Camera processes body pose locally on Mac |
| Network Transport | `Network.framework` (Bonjour Discovery `_cobainvision._tcp`) | Local Wi-Fi / P2P transport between Mac (Server/Listener) & iPhone Hub (Client/Browser) |
| Thigh Feature | CoreMotion 50 Hz device motion on iPhone | Orientation-agnostic thigh angle derived from standing vs leg raised gravity baseline |
| Watch Relay | iPhone Hub relays Watch features (15 Hz) + HR to Mac | iPhone acts as central bridge gathering Watch (`WCSession`) & local thigh data |
| Clock Sync | Chained ping-pong (Watch <-> iPhone <-> Mac) | Tracks median/P95 latency, RTT/2 one-way estimate, and clock offset across links |
| Mac Logger | JSON-lines logger (`JSONL`) | Captures synchronized multi-sensor streams with device metadata & clock offsets |

---

## File Map & Target Membership

```
CobainVision/                          <- Xcode project root
├── Config/
│   ├── AppConfig.swift                Shared: [CobainVision, CobainVisionMac]
│   └── DetectionMode.swift            Shared: [CobainVision, CobainVisionMac]
├── Pose/
│   ├── PoseProvider.swift             Shared: [CobainVision, CobainVisionMac]
│   ├── PoseFrame.swift                Shared: [CobainVision, CobainVisionMac]
│   └── VisionPoseProvider.swift       Shared: [CobainVision, CobainVisionMac]
├── Gestures/
│   ├── GestureEvent.swift             Shared: [CobainVision, CobainVisionMac]
│   ├── GestureDefinitions.swift       Shared: [CobainVision, CobainVisionMac]
│   └── GestureEngine.swift            Shared: [CobainVision, CobainVisionMac]
├── Logging/
│   └── SessionLogger.swift            Shared: [CobainVision, CobainVisionMac]
├── Transport/
│   ├── WatchTransport.swift           iOS/watchOS WCSession transport: [CobainVision]
│   ├── MacNetworkTransport.swift      Network.framework Bonjour listener/browser: [CobainVision, CobainVisionMac]
│   └── HubPayloads.swift              JSON structs for Mac <-> iPhone payload schema: [CobainVision, CobainVisionMac]
├── Hub/
│   └── ThighMotionDetector.swift      CoreMotion 50 Hz thigh angle + gravity baseline: [CobainVision]
├── Overlay/
│   └── DebugOverlayView.swift         SwiftUI Skeleton canvas & confidence HUD: [CobainVision, CobainVisionMac]
├── App/
│   ├── CobainVisionApp.swift          iOS App @main entry point: [CobainVision]
│   └── ContentView.swift              iOS Hub View (Thigh calibration, Watch relay, Mac connection status)
│
watchDetect Watch App/                 <- watchOS app target [watchDetect Watch App]
├── watchDetectApp.swift               watchOS @main entry point
├── WatchWorkoutManager.swift          HealthKit HKWorkoutSession & CMMotionManager device motion
├── WatchMotionDetector.swift          Forearm pitch & wrist shake detection algorithms
├── WatchTypes.swift                   WatchTransport protocol & WCSession implementation
└── ContentView.swift                  Calibration UI, HR display, wrist side selection & status
│
CobainVisionMac/                       <- macOS App target [CobainVisionMac]
├── CobainVisionMacApp.swift           macOS App @main entry point
├── MacDashboardView.swift             Multi-sensor live dashboard, rolling charts, camera picker & JSONL logger
```

---

## Setup & How to Run

### Prerequisites
- Xcode 27.0
- Mac (macOS) + Real iPhone (iOS 26.5.2) + Apple Watch (watchOS 26.6)
- Local Wi-Fi or peer-to-peer Wi-Fi/Bluetooth enabled for Bonjour discovery

### Running the Research Rig (Milestone H-A)
1. Open `CobainVision.xcodeproj` in Xcode.
2. Build and run `CobainVisionMac` on your Mac.
3. Build and run `CobainVision` on your iPhone (Watch app `watchDetect Watch App` installs automatically on paired Watch).
4. On iPhone: Switch to **Hub Mode** (keeps screen active via `isIdleTimerDisabled`), perform Thigh Calibration ("Standing" then "Leg Raised").
5. The iPhone automatically discovers the Mac via Bonjour (`_cobainvision._tcp`) and streams Thigh + Watch sensor features to the Mac Dashboard.
6. On Mac: Select camera device, view live camera skeleton overlay + rolling sensor charts for Watch, Thigh, and Vision, and export JSONL recordings.

---

## Known Limitations & Risks
- **Local Network / Bonjour Permissions**: iOS 14+ requires explicit `NSLocalNetworkUsageDescription` and `NSBonjourServices` in `Info.plist` for iPhone to connect to Mac over local network.
- **Mac Sandbox & Entitlements**: macOS App Sandbox requires Incoming/Outgoing Network Connections (`com.apple.security.network.client` & `server`) and Camera entitlement (`com.apple.security.device.camera`).
- **Device Placement & Accidental Touches**: iPhone must be secured to thigh (pocket/strap) while screen remains active in foreground; full-screen touch lock is required to prevent accidental leg touches.
- **iPhone Background Suspension**: If iPhone transitions to background/inactive, network stream pauses; app must report "hub paused" event to Mac dashboard.
- **Wi-Fi Jitter & Network Latency**: Local Wi-Fi network packet jitter may impact 20 Hz / 15 Hz stream latency; tracked via raw ping-pong samples (t0, t1, t2, t3), median/P95 RTT, and sequence gap counters.
- **Webcam Field of View & Lower-Body Occlusion**: Built-in Mac webcam or Continuity Camera angle must be adjusted to capture full lower body (hips, knees, ankles) for leg gestures.

---

## Milestone Status
| Milestone | Status |
|-----------|--------|
| M1 — Camera Pose & Gestures | ✅ Completed |
| Milestone W-LITE — Apple Watch + Simple Fusion | ✅ Stage 1 Complete |
| Milestone H-A — Multi-Sensor Hub + Mac Dashboard | ⏳ Step 0 Complete — Awaiting Plan Approval |

