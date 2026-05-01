//
//  TranscribeDevSettings.swift
//  VibeWindowManagerIOS
//
//  DEBUG: toggle iOS SFSpeech live (transcribeLive) vs Mac PCM+Whisper (transcribe) independently.
//  Shipped UI is behind #if DEBUG in ContentView so you can delete that block later.
//

import Foundation

enum TranscribeDevSettings {
    /// On-device SFSpeech partials → `transcribeLive` on the Mac.
    static let sfspeechTranscribeLiveKey = "vibeDevSFSpeechTranscribeLive"
    /// Mic PCM → `transcribe` on the Mac (Whisper / STT on hold end).
    static let pcmMacWhisperKey = "vibeDevPcmMacWhisper"

    static func sfspeechTranscribeLiveEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: sfspeechTranscribeLiveKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: sfspeechTranscribeLiveKey)
    }

    static func pcmMacWhisperEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: pcmMacWhisperKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: pcmMacWhisperKey)
    }

    static var anyPathEnabled: Bool {
        sfspeechTranscribeLiveEnabled() || pcmMacWhisperEnabled()
    }
}

#if DEBUG
import SwiftUI

struct TranscribeDevSettingsView: View {
    @AppStorage(TranscribeDevSettings.sfspeechTranscribeLiveKey) private var sfspeechLive: Bool = true
    @AppStorage(TranscribeDevSettings.pcmMacWhisperKey) private var pcmWhisper: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("SFSpeech live → Mac (`transcribeLive`)", isOn: $sfspeechLive)
                    Toggle("PCM → Mac Whisper (`transcribe` / final)", isOn: $pcmWhisper)
                } header: {
                    Text("Transcribe (debug)")
                } footer: {
                    Text(
                        "Turn one off to isolate the other. If both are off, hold-to-speak will not start. Toggles apply to the next recording."
                    )
                    .font(.caption)
                }
            }
            .navigationTitle("Transcribe (dev)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
