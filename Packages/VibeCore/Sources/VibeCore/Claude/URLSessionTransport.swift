import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession transport with one long-lived session, so the TLS connection to
/// the API is reused between replies (a fresh handshake would add latency to
/// every Reply). Streams are read through the session delegate, which works
/// the same on macOS and Linux.
public final class URLSessionTransport: NSObject, ClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [Int: LineStream] = [:]
    private var session: URLSession!

    public init(configuration: URLSessionConfiguration = .default) {
        super.init()
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            let stream = LineStream(continuation: continuation)
            lock.lock()
            streams[task.taskIdentifier] = stream
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.remove(task.taskIdentifier)
            }
            task.resume()
        }
    }

    public func data(for request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()
                if (200..<300).contains(status) {
                    continuation.resume(returning: body)
                } else {
                    continuation.resume(throwing: ClaudeClient.error(status: status, body: body))
                }
            }
            task.resume()
        }
    }

    private func stream(for task: URLSessionTask) -> LineStream? {
        lock.lock()
        defer { lock.unlock() }
        return streams[task.taskIdentifier]
    }

    private func remove(_ identifier: Int) {
        lock.lock()
        streams[identifier] = nil
        lock.unlock()
    }
}

extension URLSessionTransport: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        stream(for: dataTask)?.receive(response: response)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stream(for: dataTask)?.receive(data: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stream(for: task)?.complete(error: error)
        remove(task.taskIdentifier)
    }
}

/// Splits a response body into lines as bytes arrive.
final class LineStream: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var buffer = Data()
    private var status: Int?
    private var errorBody = Data()

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    private var isSuccess: Bool { (200..<300).contains(status ?? 200) }

    func receive(response: URLResponse) {
        status = (response as? HTTPURLResponse)?.statusCode
    }

    func receive(data: Data) {
        guard isSuccess else {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            continuation.yield(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    func complete(error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else if !isSuccess {
            continuation.finish(throwing: ClaudeClient.error(status: status ?? 0, body: errorBody))
        } else {
            if !buffer.isEmpty {
                continuation.yield(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll()
            }
            continuation.finish()
        }
    }
}
