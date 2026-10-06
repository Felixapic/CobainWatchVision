// WatchWorkoutManager.swift
// watchDetect Watch App — Milestone W-LITE Stage 1
//
// Manages HealthKit HKWorkoutSession + HKLiveWorkoutBuilder to keep the watchOS
// app running in background while measuring Heart Rate & Device Motion.
//
// API Verification (HealthKit):
// • HKHealthStore: requestAuthorization(toShare:read:)
// • HKWorkoutSession: init(healthStore:configuration:) (watchOS 5.0+)
// • HKLiveWorkoutBuilder: session.associatedWorkoutBuilder() (watchOS 5.0+)

import Foundation
import HealthKit
import Combine

final class WatchWorkoutManager: NSObject, ObservableObject {

    // ── Public State ─────────────────────────────────────────────────────────

    @Published private(set) var heartRate: Double?
    @Published private(set) var isSessionActive: Bool = false
    @Published private(set) var healthKitAuthGranted: Bool = false
    @Published private(set) var statusMessage: String = "Idle"

    // ── Private ──────────────────────────────────────────────────────────────

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    // ── HealthKit Authorization & Session Setup ──────────────────────────────

    func requestAuthorizationAndStart() {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "HealthKit Unavailable"
            return
        }

        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            statusMessage = "HR Type Unavailable"
            return
        }

        let typesToRead: Set<HKObjectType> = [heartRateType]
        let typesToShare: Set<HKSampleType> = [HKObjectType.workoutType()]

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.healthKitAuthGranted = true
                    self?.statusMessage = "HealthKit Authorized"
                    self?.startWorkoutSession()
                } else {
                    self?.healthKitAuthGranted = false
                    let errStr = error?.localizedDescription ?? "Denied"
                    self?.statusMessage = "HK Auth: \(errStr) (Running Motion Only)"
                    // Graceful fallback: start workout session even if auth denied (workout session keeps app backgrounded)
                    self?.startWorkoutSession()
                }
            }
        }
    }

    private func startWorkoutSession() {
        guard workoutSession == nil else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()

            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)

            session.delegate = self
            builder.delegate = self

            self.workoutSession = session
            self.workoutBuilder = builder

            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.isSessionActive = true
                        self?.statusMessage = "Workout Session Running"
                    } else {
                        let errStr = error?.localizedDescription ?? "Failed"
                        self?.statusMessage = "Workout Builder Error: \(errStr)"
                    }
                }
            }
        } catch {
            statusMessage = "Workout Session Error: \(error.localizedDescription)"
        }
    }

    func stopWorkoutSession() {
        workoutSession?.end()
        workoutBuilder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.workoutBuilder?.finishWorkout { _, _ in }
        }
        workoutSession = nil
        workoutBuilder = nil
        isSessionActive = false
        statusMessage = "Stopped"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HKWorkoutSessionDelegate & HKLiveWorkoutBuilderDelegate
// ─────────────────────────────────────────────────────────────────────────────

extension WatchWorkoutManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            switch toState {
            case .running:
                self.isSessionActive = true
                self.statusMessage = "Running"
            case .ended, .stopped:
                self.isSessionActive = false
                self.statusMessage = "Ended"
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.statusMessage = "Session Failed: \(error.localizedDescription)"
            self.isSessionActive = false
        }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType) else { return }

        if let statistics = workoutBuilder.statistics(for: heartRateType) {
            let unit = HKUnit.count().unitDivided(by: .minute())
            if let value = statistics.mostRecentQuantity()?.doubleValue(for: unit) {
                DispatchQueue.main.async {
                    self.heartRate = value
                }
            }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
