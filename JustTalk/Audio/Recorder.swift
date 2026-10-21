//
//  Recorder.swift
//  JustTalk
//
//  Запись с микрофона в память (этап 4): AVAudioEngine, tap на inputNode,
//  моно Float32, лимит длительности. Частота — нативная входная (48к),
//  ресемплинг делает sherpa-onnx (AcceptWaveform(sampleRate:)).
//

import AVFoundation

/// Все управляющие вызовы — с main; буфер копится на tap-потоке под локом.
nonisolated final class Recorder: @unchecked Sendable {
    /// Лимит записи из настроек (Настройки → Лимит записи), по умолчанию 5 мин.
    static var maxSeconds: Double {
        let v = UserDefaults.standard.integer(forKey: TranscriptionSettings.maxRecordSecondsKey)
        return Double((60...600).contains(v) ? v : 300)
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var totalFrames = 0
    private var limitFired = false
    private(set) var sampleRate: Double = 0

    /// Вызывается на main, когда запись дошла до лимита длительности.
    var onLimitReached: (@MainActor () -> Void)?

    var isRecording: Bool { engine.isRunning }

    /// Проверяет/запрашивает доступ к микрофону. Без granted
    /// AVAudioSession.setActive падает «Session activation failed».
    static func hasMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// `mixable`: запуск из фона (Action Button при закрытом приложении).
    /// Немиксуемую сессию (.record) iOS из фона не активирует; миксуемая
    /// .playAndRecord + .mixWithOthers — шанс пройти (другой звук не глушится).
    func start(mixable: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        if mixable {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        } else {
            try session.setCategory(.record, mode: .measurement)
        }
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        lock.lock()
        chunks.removeAll()
        totalFrames = 0
        limitFired = false
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Откат: без этого активная сессия не даст устройству уснуть.
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    /// Останавливает запись и возвращает накопленное.
    func stop() -> (samples: [Float], sampleRate: Double) {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)

        lock.lock()
        let flat = chunks.flatMap { $0 }
        chunks.removeAll()
        let rate = sampleRate
        lock.unlock()
        return (flat, rate)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)

        var samples = [Float](repeating: 0, count: frames)
        if channels == 1 {
            samples = Array(UnsafeBufferPointer(start: data[0], count: frames))
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                samples[i] = sum / Float(channels)
            }
        }

        var hitLimit = false
        lock.lock()
        chunks.append(samples)
        totalFrames += frames
        if !limitFired,
           sampleRate > 0,
           Double(totalFrames) / sampleRate >= Self.maxSeconds {
            limitFired = true
            hitLimit = true
        }
        lock.unlock()

        if hitLimit {
            Task { @MainActor [onLimitReached] in onLimitReached?() }
        }
    }
}
