import Foundation

/// Downloads a release archive to a temporary file, reporting progress.
///
/// `URLSession`'s async download API hands back the finished file but no progress, and a 13 MB
/// download on a bad connection needs a moving bar, so this drives a session-level delegate and
/// bridges it back with a continuation.
public final class UpdateDownloader: NSObject, @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    public override init() { super.init() }

    /// - Returns: a local file the caller owns (delete it when done).
    public func download(
        _ url: URL,
        timeout: TimeInterval = 30 * 60,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let delegate = Delegate(onProgress: onProgress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = timeout
        // The temp file `didFinishDownloadingTo` hands us is deleted the moment we return, so it has
        // to be moved before the delegate method exits; the session is kept alive until then.
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.resume(continuation, task: task)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: ProgressHandler
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var destination: URL?

        init(onProgress: @escaping ProgressHandler) { self.onProgress = onProgress }

        func resume(_ continuation: CheckedContinuation<URL, Error>, task: URLSessionDownloadTask) {
            lock.withLock { self.continuation = continuation }
            // Fixed up front so the move in `didFinishDownloadingTo` can't fail on a path that was
            // never made.
            destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-update-\(UUID().uuidString).zip")
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard let destination else {
                finish(.failure(UpdateError.corruptArchive("The download had nowhere to go.")))
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                onProgress(1)
                finish(.success(destination))
            } catch {
                finish(.failure(UpdateError.corruptArchive("Couldn't save the download: \(error.localizedDescription)")))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let urlError = error as? URLError
            if urlError?.code == .cancelled {
                finish(.failure(UpdateError.cancelled))
            } else {
                finish(.failure(UpdateError.network(error.localizedDescription)))
            }
        }

        private func finish(_ result: Result<URL, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}