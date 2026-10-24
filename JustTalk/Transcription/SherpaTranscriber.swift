//
//  SherpaTranscriber.swift
//  JustTalk
//
//  Обёртка sherpa-onnx OfflineRecognizer для Qwen3-ASR.
//  Порт LocalTranscriber.kt; параметры — из swift-api-examples/qwen3-asr.swift.
//

import Foundation
import SherpaOnnx

/// Движок распознавания за этим протоколом — чтобы позже подменить
/// (например, на Whisper через тот же sherpa-onnx, ветка detectModelConfig).
nonisolated protocol Transcriber {
    func transcribe(_ samples: [Float], sampleRate: Int) -> String
}

/// Сериализация вызовов — на стороне вызывающего (одна запись одновременно).
nonisolated final class SherpaTranscriber: Transcriber, @unchecked Sendable {
    /// A17 Pro: 6 ядер. На Android оптимальны 4 больших ядра — замерить 4 vs 6 (этап 3).
    static let defaultThreads = ProcessInfo.processInfo.activeProcessorCount

    private let recognizer: SherpaOnnxOfflineRecognizer
    let numThreads: Int

    /// Создаёт транскрайбер или nil, если sherpa-onnx не принял конфигурацию
    /// (файлы уже проверены `ModelStore.validate`, так что отказ маловероятен).
    static func make(modelFiles: Qwen3ModelFiles, numThreads: Int = SherpaTranscriber.defaultThreads) -> SherpaTranscriber? {
        let sw = sherpaOnnxOfflineQwen3ASRModelConfig(
            convFrontend: modelFiles.convFrontend.path,
            encoder: modelFiles.encoder.path,
            decoder: modelFiles.decoder.path,
            tokenizer: modelFiles.tokenizer.path
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: numThreads,
                provider: "cpu",
                qwen3Asr: sw
            )
        )
        // C-сторона копирует конфигурацию внутри SherpaOnnxCreateOfflineRecognizer.
        let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        return SherpaTranscriber(recognizer: recognizer, numThreads: numThreads)
    }

    private init(recognizer: SherpaOnnxOfflineRecognizer, numThreads: Int) {
        self.recognizer = recognizer
        self.numThreads = numThreads
    }

    /// Блокирующий вызов — только из фонового потока/задачи.
    func transcribe(_ samples: [Float], sampleRate: Int = 16000) -> String {
        Self.stripQwenMarkup(recognizer.decode(samples: samples, sampleRate: sampleRate).text)
    }

    /// Qwen3-ASR иногда отдаёт сырой вывод с разметкой:
    /// «language Russian<asr_text>Текст.</asr_text>» — оставляем только текст.
    static func stripQwenMarkup(_ raw: String) -> String {
        var text = raw
        if let open = text.range(of: "<asr_text>", options: .backwards) {
            text = String(text[open.upperBound...])
        }
        if let close = text.range(of: "</asr_text>") {
            text = String(text[..<close.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
