//
//  ModelDownloader.swift
//  JustTalk
//
//  Загрузчик моделей (этап 7): качает комплект файлов варианта
//  поштучно с HuggingFace (resolve/main) в Documents/models/<каталог>.
//  Без архивов: conv_frontend.onnx + encoder/decoder int8 + tokenizer/.
//  Транспорт — URLSessionDownloadTask (полная скорость CDN, докачка
//  через resumeData при обрыве, до 5 попыток на файл, отмена).
//

import Foundation
import Observation

@MainActor
@Observable
final class ModelDownloader {
    static let shared = ModelDownloader()

    /// Общий прогресс комплекта по байтам, 0…1.
    struct Progress: Equatable {
        var fraction: Double
    }

    enum Phase: Equatable {
        case idle
        case downloading(Progress)
        case verifying
        case done
        case failed(String)
    }

    /// Что сейчас качается (nil — ничего) и текущая фаза.
    private(set) var activeVariantId: String?
    private(set) var phase: Phase = .idle
    /// Вариант, чья последняя загрузка упала (для строки ошибки в настройках;
    /// activeVariantId к этому моменту уже сброшен).
    private(set) var failedVariantId: String?

    private var task: Task<Void, Never>?

    private init() {}

    func isDownloading(_ variantId: String) -> Bool { activeVariantId == variantId }

    /// Начать загрузку варианта. Каталог создаётся, готовые файлы пропускаются.
    func start(variant: ModelVariant) {
        guard task == nil else { return }
        activeVariantId = variant.id
        failedVariantId = nil
        let store = ModelStore()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.download(variant: variant, progress: { progress in
                    Task { @MainActor in self.phase = .downloading(progress) }
                })
                phase = .verifying
                switch store.installedState(variant) {
                case .ready:
                    phase = .done
                case .corrupted(let reasons):
                    phase = .failed("Файлы повреждены: " + reasons.joined(separator: "; "))
                    failedVariantId = variant.id
                case .notFound, nil:
                    phase = .failed("Каталог модели не найден после загрузки")
                    failedVariantId = variant.id
                }
            } catch is CancellationError {
                phase = .idle
                Self.removeIncomplete(variant: variant)
            } catch {
                let code = (error as? URLError).map { " (\($0.code.rawValue))" } ?? ""
                phase = .failed(error.localizedDescription + code)
                failedVariantId = variant.id
                Self.removeIncomplete(variant: variant)
            }
            task = nil
            activeVariantId = nil
        }
    }

    /// Отмена загрузки: обрываем сеть, чистим недокачанные файлы.
    func cancel() {
        task?.cancel()
    }

    // MARK: - Сетевая часть (вне main actor)

    nonisolated private static func download(
        variant: ModelVariant,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let dir = ModelStore.variantDirectory(variant)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let files = variant.downloadFiles
        func remoteURL(_ relativePath: String) -> URL {
            URL(string: "https://huggingface.co/\(variant.hfRepo)/resolve/main/\(relativePath)")!
        }

        // Размеры заранее: и для пропуска готовых файлов, и для проверки места.
        var expectedSizes: [String: Int64] = [:]
        for relativePath in files {
            try Task.checkCancellation()
            expectedSizes[relativePath] = try? await remoteLength(url: remoteURL(relativePath))
        }
        let needed = files.reduce(Int64(0)) { sum, path in
            guard let expected = expectedSizes[path] else { return sum }
            let dest = dir.appendingPathComponent(path)
            return localLength(dest) == expected ? sum : sum + expected
        }
        if let available = availableSpace(at: dir) {
            // Запас 200 МБ: staging-файл и системе.
            let required = needed + 200_000_000
            if available < required {
                throw DownloadError.notEnoughSpace(needed: required, available: available)
            }
        }

        // Общий прогресс: байты готовых файлов + текущего, от суммы оставшихся.
        var completedBytes: Int64 = 0
        progress(Progress(fraction: 0))

        for relativePath in files {
            try Task.checkCancellation()
            let dest = dir.appendingPathComponent(relativePath)

            // Подкаталог tokenizer/.
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Докачка комплекта: готовый файл того же размера не качаем повторно.
            let url = remoteURL(relativePath)
            if let expected = expectedSizes[relativePath], localLength(dest) == expected { continue }

            let fileSize = expectedSizes[relativePath] ?? 0
            let doneBefore = completedBytes
            let report: @Sendable (Double) -> Void = { fraction in
                guard needed > 0 else { return }
                let bytes = Double(doneBefore) + fraction * Double(fileSize)
                progress(Progress(fraction: min(1, bytes / Double(needed))))
            }
            try await downloadFile(
                url: url, to: dest,
                expectedSize: expectedSizes[relativePath],
                progress: report
            )
            completedBytes += fileSize
        }
    }

    /// Content-Length по HEAD (HF отдаёт редирект на CDN — URLSession следует сам).
    nonisolated private static func remoteLength(url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        if http.expectedContentLength >= 0 { return http.expectedContentLength }
        return http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    }

    /// Качает файл download-таском (полная скорость CDN), перемещает на место.
    /// Обрыв сети → продолжение через resumeData; до 5 попыток на файл.
    nonisolated private static func downloadFile(
        url: URL, to dest: URL,
        expectedSize: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60

        let staging = dest.appendingPathExtension("download")
        var resumeData: Data?
        for attempt in 1...5 {
            try Task.checkCancellation()
            let delegate = DownloadDelegate(
                staging: staging, expectedSize: expectedSize, progress: progress
            )
            let session = URLSession(
                configuration: config, delegate: delegate, delegateQueue: nil
            )
            do {
                let tmpURL = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        delegate.continuation = continuation
                        let task = resumeData.map(session.downloadTask(withResumeData:))
                            ?? session.downloadTask(with: url)
                        delegate.task = task
                        task.resume()
                    }
                } onCancel: {
                    delegate.task?.cancel()
                }
                session.finishTasksAndInvalidate()
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: tmpURL, to: dest)
                return
            } catch {
                session.finishTasksAndInvalidate()
                try? FileManager.default.removeItem(at: staging)
                if error is CancellationError { throw error }
                // Неудавшаяся докачка (resumeData) может падать раз за разом
                // (например 416 от CDN) — следующая попытка строго с нуля.
                resumeData = nil
                if attempt == 5 {
                    throw error
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    nonisolated private static func availableSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated private static func localLength(_ url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? Int64
    }

    /// Убирает недокачанные хвосты: .download (staging) и .part (прежняя версия).
    nonisolated private static func removeIncomplete(variant: ModelVariant) {
        let dir = ModelStore.variantDirectory(variant)
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let entry = enumerator?.nextObject() as? URL {
            if ["part", "download"].contains(entry.pathExtension) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            "Сервер ответил HTTP \(code)"
        case .notEnoughSpace(let needed, let available):
            "Мало места: нужно \(Self.gb(needed)), свободно \(Self.gb(available))"
        }
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f ГБ", Double(bytes) / 1_000_000_000)
    }
}

/// Делегат одного скачиваемого файла: прогресс, завершение, resumeData.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    /// Куда переносится скачанный файл до возврата из didFinishDownloadingTo.
    let staging: URL
    /// Размер из HEAD — если сервер не сообщил его в ответе (сжатие/chunked).
    let expectedSize: Int64?
    var continuation: CheckedContinuation<URL, Error>?
    var resumeData: Data?
    var task: URLSessionDownloadTask?

    init(staging: URL, expectedSize: Int64?, progress: @escaping @Sendable (Double) -> Void) {
        self.staging = staging
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedSize ?? 0)
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    /// `location` удаляется системой сразу после возврата из этого метода,
    /// поэтому файл переносится в staging синхронно, здесь же.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let continuation else { return }
        self.continuation = nil

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            continuation.resume(throwing: DownloadError.httpStatus(http.statusCode))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: staging.path) {
                try fm.removeItem(at: staging)
            }
            try fm.moveItem(at: location, to: staging)
            progress(1)
            continuation.resume(returning: staging)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        defer { self.continuation = nil }

        guard let error else { return }
        // resumeData берём из ошибки download-таска (классический путь).
        if let urlError = task.error as? URLError,
           let data = urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        if (error as? URLError)?.code == .cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(throwing: error)
        }
    }
}
