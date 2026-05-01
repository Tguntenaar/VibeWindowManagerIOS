//
//  HoldToSpeakRecorder.swift
//  VibeWindowManagerIOS
//
//  Captures mono 16 kHz 16-bit little-endian PCM and streams it as base64 over the bridge
//  (format `pcm_s16le_16000` per docs/PROTOCOL.md).
//

import AVFoundation
import Combine
import Foundation
import Speech

/// Conversion + pending PCM live on a dedicated `CaptureState` so the audio thread never touches
/// the main `BridgeClient` (which is main-actor isolated).
private final class CaptureState: @unchecked Sendable {
    var converter: AVAudioConverter
    var fromFormat: AVAudioFormat
    let toFormat: AVAudioFormat
    let lock = NSLock()
    var pendingPcm = Data()

    init(converter: AVAudioConverter, fromFormat: AVAudioFormat, toFormat: AVAudioFormat) {
        self.converter = converter
        self.fromFormat = fromFormat
        self.toFormat = toFormat
    }

    /// Called from the audio I/O thread.
    func ingest(buffer: AVAudioPCMBuffer) {
        let inFmt = fromFormat
        let outFmt = toFormat
        let ratio = outFmt.sampleRate / inFmt.sampleRate
        let outFrames = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)))
        guard
            let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames)
        else { return }
        var error: NSError?
        var consumed = false
        let input: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        _ = converter.convert(to: out, error: &error, withInputFrom: input)
        if error != nil { return }
        let n = out.frameLength
        guard n > 0, let ch = out.int16ChannelData else { return }
        let c0 = ch[0]
        let nInt = Int(n)
        var chunk = Data(count: nInt * 2)
        chunk.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<nInt {
                dst[i] = c0[i]
            }
        }
        lock.lock()
        pendingPcm.append(chunk)
        lock.unlock()
    }

    /// Called on the main run loop. Returns a slice to send with `end: false`.
    func takePending() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if pendingPcm.isEmpty { return nil }
        let d = pendingPcm
        pendingPcm.removeAll(keepingCapacity: true)
        return d
    }

    /// Clears any tail without sending (used on failure).
    func clear() {
        lock.lock()
        pendingPcm.removeAll()
        lock.unlock()
    }
}

/// Forwards mic buffers to `SFSpeechAudioBufferRecognitionRequest` from the I/O thread without crossing `MainActor`.
private final class SpeechBufferForwarder: @unchecked Sendable {
    var request: SFSpeechAudioBufferRecognitionRequest?
    let lock = NSLock()
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(buffer)
    }
    /// Clears the ref and returns the request to call `endAudio()` (once) on the main run loop.
    func takeForEnd() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let r = request
        request = nil
        lock.unlock()
        return r
    }
}

@MainActor
final class HoldToSpeakRecorder: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    /// On-device `SFSpeechRecognizer` partials (Apple); Mac Whisper still does final paste.
    @Published var liveTranscript: String = ""

    private var engine: AVAudioEngine?
    private var state: CaptureState?
    private var chunkTimer: Timer?
    private weak var bridge: BridgeClient?
    private var speechForwarder: SpeechBufferForwarder?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var liveMacDebounce: Task<Void, Never>?
    private var liveMacSendPending: String = ""

    private static let chunkInterval: TimeInterval = 0.12
    private static let liveMacDebounceNs: UInt64 = 120_000_000

    private static func makePcmS16_16kMono() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
    }

    func start(bridge: BridgeClient) {
        self.bridge = bridge
        lastError = nil
        liveTranscript = ""
        guard !isRunning else { return }
        guard TranscribeDevSettings.anyPathEnabled else {
            lastError = "Both transcribe paths are off (Dev → Transcribe). Turn at least one on."
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                if !allowed {
                    self.lastError = "Microphone access denied. Enable in Settings."
                    return
                }
                if TranscribeDevSettings.sfspeechTranscribeLiveEnabled() {
                    SFSpeechRecognizer.requestAuthorization { [weak self] status in
                        Task { @MainActor in
                            guard let self else { return }
                            self.startAfterPermission(bridge: bridge, speechAuth: status)
                        }
                    }
                } else {
                    self.startAfterPermission(bridge: bridge, speechAuth: .denied)
                }
            }
        }
    }

    private func startAfterPermission(bridge: BridgeClient, speechAuth: SFSpeechRecognizerAuthorizationStatus) {
        do {
            try configureSession()
            try startEngine(bridge: bridge, speechAuth: speechAuth)
            isRunning = true
        } catch {
            tearDown()
            lastError = (error as NSError).localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }
        if TranscribeDevSettings.sfspeechTranscribeLiveEnabled(), let b = bridge, !liveTranscript.isEmpty {
            b.sendTranscribeLive(text: liveTranscript)
        }
        liveMacDebounce?.cancel()
        liveMacDebounce = nil
        liveMacSendPending = ""
        chunkTimer?.invalidate()
        chunkTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        if let fwd = speechForwarder, let req = fwd.takeForEnd() {
            req.endAudio()
        }
        speechForwarder = nil
        speechTask?.cancel()
        speechTask = nil
        speechRecognizer = nil
        liveTranscript = ""
        engine?.stop()
        engine = nil
        if TranscribeDevSettings.pcmMacWhisperEnabled(), let s = state, let tail = s.takePending(), !tail.isEmpty {
            bridge?.sendTranscribeChunk(base64: tail.base64EncodedString(), end: false)
        } else {
            state?.clear()
        }
        state = nil
        isRunning = false
        if TranscribeDevSettings.pcmMacWhisperEnabled() {
            bridge?.sendTranscribeChunk(base64: "", end: true)
        }
    }

    // MARK: - Internals

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try s.setActive(true, options: [])
    }

    private func startEngine(bridge: BridgeClient, speechAuth: SFSpeechRecognizerAuthorizationStatus) throws {
        self.bridge = bridge
        let usePcm = TranscribeDevSettings.pcmMacWhisperEnabled()
        let useLiveSpeech = TranscribeDevSettings.sfspeechTranscribeLiveEnabled() && speechAuth == .authorized

        let e = AVAudioEngine()
        let inNode = e.inputNode
        let fromFormat = inNode.outputFormat(forBus: 0)
        var cap: CaptureState?
        if usePcm {
            guard let toFormat = Self.makePcmS16_16kMono() else {
                throw NSError(
                    domain: "HoldToSpeak",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "16 kHz mono int16 format unavailable."]
                )
            }
            guard let conv = AVAudioConverter(from: fromFormat, to: toFormat) else {
                throw NSError(
                    domain: "HoldToSpeak",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not build audio resampler (mic format unsupported)."]
                )
            }
            cap = CaptureState(converter: conv, fromFormat: fromFormat, toFormat: toFormat)
        }
        var fwd: SpeechBufferForwarder?
        if useLiveSpeech {
            // Pin to the device locale so non‑English (e.g. Dutch) can get live partials from the
            // correct on-device model instead of falling through to a default recognizer only.
            let rec: SFSpeechRecognizer? = {
                if let r = SFSpeechRecognizer(locale: .current), r.isAvailable { return r }
                if let r = SFSpeechRecognizer(), r.isAvailable { return r }
                return nil
            }()
            if let rec {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                if #available(iOS 16, *) {
                    request.addsPunctuation = true
                }
                self.speechRecognizer = rec
                let forwarder = SpeechBufferForwarder()
                forwarder.request = request
                fwd = forwarder
                self.speechForwarder = forwarder
                self.speechTask = rec.recognitionTask(with: request) { [weak self] result, _ in
                    Task { @MainActor in
                        guard let self, let r = result else { return }
                        let t = r.bestTranscription.formattedString
                        if !t.isEmpty {
                            self.liveTranscript = t
                            if let b = self.bridge { self.debounceSendTranscribeLive(bridge: b, text: t) }
                        }
                    }
                }
            } else {
                self.speechForwarder = nil
                self.speechTask = nil
                self.speechRecognizer = nil
            }
        } else {
            self.speechForwarder = nil
            self.speechTask = nil
            self.speechRecognizer = nil
        }
        inNode.removeTap(onBus: 0)
        inNode.installTap(onBus: 0, bufferSize: 4096, format: fromFormat) { buffer, _ in
            cap?.ingest(buffer: buffer)
            fwd?.append(buffer)
        }
        e.prepare()
        do {
            try e.start()
        } catch {
            inNode.removeTap(onBus: 0)
            speechTask?.cancel()
            speechTask = nil
            speechRecognizer = nil
            if let fwd2 = speechForwarder, let req = fwd2.takeForEnd() {
                req.endAudio()
            }
            speechForwarder = nil
            throw error
        }
        engine = e
        state = cap
        if usePcm {
            chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.flushTick()
                }
            }
        }
    }

    private func flushTick() {
        guard TranscribeDevSettings.pcmMacWhisperEnabled(), let s = state else { return }
        if let d = s.takePending(), !d.isEmpty {
            bridge?.sendTranscribeChunk(base64: d.base64EncodedString(), end: false)
        }
    }

    private func debounceSendTranscribeLive(bridge: BridgeClient, text: String) {
        guard TranscribeDevSettings.sfspeechTranscribeLiveEnabled() else { return }
        liveMacSendPending = text
        liveMacDebounce?.cancel()
        liveMacDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.liveMacDebounceNs)
            guard !Task.isCancelled else { return }
            let toSend = self.liveMacSendPending
            bridge.sendTranscribeLive(text: toSend)
        }
    }

    private func tearDown() {
        liveMacDebounce?.cancel()
        liveMacDebounce = nil
        liveMacSendPending = ""
        chunkTimer?.invalidate()
        chunkTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        if let fwd = speechForwarder, let req = fwd.takeForEnd() {
            req.endAudio()
        }
        speechForwarder = nil
        speechTask?.cancel()
        speechTask = nil
        speechRecognizer = nil
        liveTranscript = ""
        state?.clear()
        state = nil
        engine?.stop()
        engine = nil
        isRunning = false
    }
}
