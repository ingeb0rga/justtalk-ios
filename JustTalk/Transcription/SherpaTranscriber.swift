//
//  SherpaTranscriber.swift
//  JustTalk
//
//  Обёртка sherpa-onnx OfflineRecognizer: Qwen3-ASR, GigaAM v3 (NeMo RNN-T),
//  Whisper large-v3-turbo. Параметры — из swift-api-examples sherpa-onnx.
//  Whisper и GigaAM получают запись кусками ≤ maxChunkSeconds, разрезанной
//  по самым тихим местам (без VAD-модели).
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
    private let engine: ModelEngine
    let numThreads: Int

    /// Создаёт транскрайбер или nil, если sherpa-onnx не принял конфигурацию
    /// (файлы уже проверены `ModelStore.validate`, так что отказ маловероятен).
    static func make(modelFiles: ModelFiles, numThreads: Int = SherpaTranscriber.defaultThreads) -> SherpaTranscriber? {
        // Тип C-структуры не виден из модуля SherpaOnnx — выводим через switch-выражение.
        let modelConfig = switch modelFiles.engine {
        case .qwen3:
            sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: numThreads,
                provider: "cpu",
                qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(
                    convFrontend: modelFiles.url(.convFrontend).path,
                    encoder: modelFiles.url(.encoder).path,
                    decoder: modelFiles.url(.decoder).path,
                    tokenizer: modelFiles.url(.tokenizer).path
                )
            )
        case .nemoTransducer:
            // Размерность признаков и нормализацию NeMo-модели sherpa-onnx
            // берёт из метаданных onnx.
            sherpaOnnxOfflineModelConfig(
                tokens: modelFiles.url(.tokens).path,
                transducer: sherpaOnnxOfflineTransducerModelConfig(
                    encoder: modelFiles.url(.encoder).path,
                    decoder: modelFiles.url(.decoder).path,
                    joiner: modelFiles.url(.joiner).path
                ),
                numThreads: numThreads,
                provider: "cpu",
                modelType: "nemo_transducer"
            )
        case .whisper:
            // language "" — автоопределение языка.
            sherpaOnnxOfflineModelConfig(
                tokens: modelFiles.url(.tokens).path,
                whisper: sherpaOnnxOfflineWhisperModelConfig(
                    encoder: modelFiles.url(.encoder).path,
                    decoder: modelFiles.url(.decoder).path,
                    language: "",
                    task: "transcribe"
                ),
                numThreads: numThreads,
                provider: "cpu"
            )
        }
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        // C-сторона копирует конфигурацию внутри SherpaOnnxCreateOfflineRecognizer.
        let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        return SherpaTranscriber(recognizer: recognizer, engine: modelFiles.engine, numThreads: numThreads)
    }

    private init(recognizer: SherpaOnnxOfflineRecognizer, engine: ModelEngine, numThreads: Int) {
        self.recognizer = recognizer
        self.engine = engine
        self.numThreads = numThreads
    }

    /// Блокирующий вызов — только из фонового потока/задачи.
    func transcribe(_ samples: [Float], sampleRate: Int = 16000) -> String {
        guard let maxSeconds = engine.maxChunkSeconds else {
            return Self.stripQwenMarkup(recognizer.decode(samples: samples, sampleRate: sampleRate).text)
        }
        let chunks = Self.splitAtPauses(samples, sampleRate: sampleRate, maxSeconds: maxSeconds)
        return chunks
            .map { recognizer.decode(samples: Array(samples[$0]), sampleRate: sampleRate).text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Режет запись на куски ≤ maxSeconds: каждый разрез — в самом тихом
    /// окне 0,3 с в последних двух третях допустимого куска (паузы между фразами).
    static func splitAtPauses(_ samples: [Float], sampleRate: Int, maxSeconds: Double) -> [Range<Int>] {
        let maxLen = Int(maxSeconds * Double(sampleRate))
        guard sampleRate > 0, samples.count > maxLen else { return [0..<samples.count] }
        let window = max(1, sampleRate * 3 / 10)
        let step = max(1, sampleRate / 20)
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLen {
            let searchFrom = start + maxLen / 3
            let searchTo = start + maxLen - window
            var bestCut = start + maxLen
            var bestEnergy = Float.greatestFiniteMagnitude
            var pos = searchFrom
            while pos <= searchTo {
                var energy: Float = 0
                for i in pos..<(pos + window) { energy += samples[i] * samples[i] }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestCut = pos + window / 2
                }
                pos += step
            }
            ranges.append(start..<bestCut)
            start = bestCut
        }
        ranges.append(start..<samples.count)
        return ranges
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
