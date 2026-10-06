// DetectionMode.swift
// MovementPrompt PoC
//
// Defined in its own file so both AppConfig and the GestureEngine
// can import it without circular dependencies.

/// The active sensor combination driving gesture detection.
/// M1 supports cameraOnly only. watchOnly and fusion are added in M3.
enum DetectionMode: String, Codable, CaseIterable {
    case cameraOnly
    case watchOnly   // M3
    case fusion      // M3

    var displayName: String {
        switch self {
        case .cameraOnly: return "Camera Only"
        case .watchOnly:  return "Watch Only"
        case .fusion:     return "Fusion"
        }
    }
}
