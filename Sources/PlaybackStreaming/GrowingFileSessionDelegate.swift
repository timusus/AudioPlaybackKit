import Foundation

/// The per-task URLSession delegate of a ``GrowingFileByteSource``, so the source's public type
/// does not conform to `URLSessionDataDelegate`. The running task retains this object and it
/// retains the source, as the task retained the source before; `cancel()` releases the task.
final class SessionDelegate: NSObject, URLSessionDataDelegate {
    private let source: GrowingFileByteSource

    init(_ source: GrowingFileByteSource) {
        self.source = source
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        source.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: newRequest,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        source.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        source.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        source.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        source.urlSession(session, task: task, didCompleteWithError: error)
    }
}
