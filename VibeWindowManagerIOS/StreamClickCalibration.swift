//
//  StreamClickCalibration.swift
//  VibeWindowManagerIOS
//
//  Nudges `windowStreamClick` (nx, ny) when Mac capture and AX window frame do not line up 1:1.
//

import Foundation
import SwiftUI

enum StreamClickCalibration {
    static let offsetNXKey = "vibeStreamClickOffsetNX"
    static let offsetNYKey = "vibeStreamClickOffsetNY"
    static let defaultRange: ClosedRange<Double> = -0.2 ... 0.2

    private static func storedOffset(for key: String) -> Double {
        if UserDefaults.standard.object(forKey: key) == nil { return 0 }
        return UserDefaults.standard.double(forKey: key)
    }

    static func offsetNX() -> Double { storedOffset(for: offsetNXKey) }
    static func offsetNY() -> Double { storedOffset(for: offsetNYKey) }

    /// Replaces the saved nudges (same keys as the sliders / `@AppStorage`).
    static func setOffsets(nx: Double, ny: Double) {
        UserDefaults.standard.set(nx, forKey: offsetNXKey)
        UserDefaults.standard.set(ny, forKey: offsetNYKey)
    }

    /// Offsets are added in **normalized** 0…1 space (top-left in the JPEG), then clamped.
    static func applyToNormalized(nx: Double, ny: Double) -> (nx: Double, ny: Double) {
        (min(1, max(0, nx + offsetNX())), min(1, max(0, ny + offsetNY())))
    }
}

struct StreamClickCalibrationView: View {
    @ObservedObject var bridge: BridgeClient
    @AppStorage(StreamClickCalibration.offsetNXKey) private var offNX: Double = 0
    @AppStorage(StreamClickCalibration.offsetNYKey) private var offNY: Double = 0
    @Environment(\.dismiss) private var dismiss
    private let r = StreamClickCalibration.defaultRange

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let s = bridge.streamClickCalibrationSession {
                        Text("The Mac uses a full-screen target; the dot jumps after each tap. Tap the dot in the live tile for each of \(s.sampleCount) positions.")
                        if s.awaitingReposition {
                            Text("Wait for the next dot on the Mac…")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(s.perSample.count) / \(s.sampleCount) samples")
                    } else {
                        Text("The Mac will show a full-screen white window; the black dot moves to a new random place after each iPad tap so you can see drift or non-linear error across the area.")
                    }
                    Button("Start (show target on Mac)") {
                        bridge.beginStreamClickCalibrationTapping()
                    }
                    if bridge.streamClickCalibrationSession != nil {
                        Button("Cancel", role: .cancel) {
                            bridge.cancelStreamClickCalibrationTapping()
                        }
                    }
                } header: {
                    Text("Automatic (dot on Mac)")
                }
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("→ Right")
                        Slider(value: $offNX, in: r, step: 0.0025)
                        Text(String(format: "%.3f", offNX))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("↓ Down")
                        Slider(value: $offNY, in: r, step: 0.0025)
                        Text(String(format: "%.3f", offNY))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                    Button("Reset to zero", role: .none) {
                        offNX = 0
                        offNY = 0
                    }
                } header: {
                    Text("Nudge in image space (0…1)")
                } footer: {
                    Text(
                        "Applied after the aspect-fill mapping. If taps land to the right of the target, nudge “Right” left (negative). If they land high, nudge “Down” up (negative). Values are saved."
                    )
                    .font(.caption)
                }
            }
            .navigationTitle("Stream click")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
