import Foundation
import PromiseKit

public enum HTTP {
    private static let sslURLSession = URLSession(configuration: .ephemeral)
    private static let defaultURLSession = URLSession(configuration: .ephemeral, delegate: defaultURLSessionDelegate, delegateQueue: nil)
    private static let defaultURLSessionDelegate = DefaultURLSessionDelegateImplementation()

    // MARK: Settings
    public static let timeout: TimeInterval = 10

    // MARK: URL Session Delegate Implementation
    private final class DefaultURLSessionDelegateImplementation : NSObject, URLSessionDelegate {

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Snode to snode communication uses self-signed certificates but clients can safely ignore this
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        }
    }

    // MARK: Verb
    public enum Verb : String {
        case get = "GET"
        case put = "PUT"
        case post = "POST"
        case delete = "DELETE"
    }

    // MARK: Error
    public enum Error : LocalizedError {
        case generic
        case httpRequestFailed(statusCode: UInt, json: JSON?)
        case invalidJSON

        public var errorDescription: String? {
            switch self {
            case .generic: return "An error occurred."
            case .httpRequestFailed(let statusCode, _): return "HTTP request failed with status code: \(statusCode)."
            case .invalidJSON: return "Invalid JSON."
            }
        }
    }

    // MARK: Main
    public static func execute(_ verb: Verb, _ url: String, timeout: TimeInterval = HTTP.timeout, useSSLURLSession: Bool = false) -> Promise<JSON> {
        return execute(verb, url, body: nil, timeout: timeout, useSSLURLSession: useSSLURLSession)
    }

    public static func execute(_ verb: Verb, _ url: String, parameters: JSON?, timeout: TimeInterval = HTTP.timeout, useSSLURLSession: Bool = false) -> Promise<JSON> {
        if let parameters = parameters {
            do {
                guard JSONSerialization.isValidJSONObject(parameters) else { return Promise(error: Error.invalidJSON) }
                let body = try JSONSerialization.data(withJSONObject: parameters, options: [ .fragmentsAllowed ])
                return execute(verb, url, body: body, timeout: timeout, useSSLURLSession: useSSLURLSession)
            } catch (let error) {
                return Promise(error: error)
            }
        } else {
            return execute(verb, url, body: nil, timeout: timeout, useSSLURLSession: useSSLURLSession)
        }
    }

    public static func execute(_ verb: Verb, _ url: String, body: Data?, timeout: TimeInterval = HTTP.timeout, useSSLURLSession: Bool = false) -> Promise<JSON> {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = verb.rawValue
        request.httpBody = body
        request.timeoutInterval = timeout
        request.allHTTPHeaderFields?.removeValue(forKey: "User-Agent")
        let (promise, seal) = Promise<JSON>.pending()
        let urlSession = useSSLURLSession ? sslURLSession : defaultURLSession
        let task = urlSession.dataTask(with: request) { data, response, error in
            guard let data = data, let response = response as? HTTPURLResponse else {
                if let error = error {
                    SNLog("\(verb.rawValue) request to \(url) failed due to error: \(error).")
                } else {
                    SNLog("\(verb.rawValue) request to \(url) failed.")
                }
                // Override the actual error so that we can correctly catch failed requests in sendOnionRequest(invoking:on:with:)
                return seal.reject(Error.httpRequestFailed(statusCode: 0, json: nil))
            }
            if let error = error {
                SNLog("\(verb.rawValue) request to \(url) failed due to error: \(error).")
                // Override the actual error so that we can correctly catch failed requests in sendOnionRequest(invoking:on:with:)
                return seal.reject(Error.httpRequestFailed(statusCode: 0, json: nil))
            }
            let statusCode = UInt(response.statusCode)
            var json: JSON? = nil
            if let j = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON {
                json = j
            } else if let result = String(data: data, encoding: .utf8) {
                json = [ "result" : result ]
            }
            guard 200...299 ~= statusCode else {
                let jsonDescription = json?.prettifiedDescription ?? "no debugging info provided"
                SNLog("\(verb.rawValue) request to \(url) failed with status code: \(statusCode) (\(jsonDescription)).")
                return seal.reject(Error.httpRequestFailed(statusCode: statusCode, json: json))
            }
            if let json = json {
                seal.fulfill(json)
            } else {
                SNLog("Couldn't parse JSON returned by \(verb.rawValue) request to \(url).")
                return seal.reject(Error.invalidJSON)
            }
        }
        task.resume()
        return promise
    }
}
