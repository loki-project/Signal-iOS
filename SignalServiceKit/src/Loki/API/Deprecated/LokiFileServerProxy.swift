import PromiseKit
import SessionMetadataKit

internal class LokiFileServerProxy : LokiHTTPClient {
    private let server: String
    private let keyPair = Curve25519.generateKeyPair()

    private static let fileServerPublicKey: Data = {
        let base64EncodedPublicKey = "BWJQnVm97sQE3Q1InB4Vuo+U/T1hmwHBv0ipkiv8tzEc"
        let publicKeyWithPrefix = Data(base64Encoded: base64EncodedPublicKey)!
        let hexEncodedPublicKeyWithPrefix = publicKeyWithPrefix.toHexString()
        let hexEncodedPublicKey = hexEncodedPublicKeyWithPrefix.removing05PrefixIfNeeded()
        return Data(hex: hexEncodedPublicKey)
    }()

    // MARK: Error
    internal enum Error : LocalizedError {
        case symmetricKeyGenerationFailed
        case endpointParsingFailed
        case proxyResponseParsingFailed
        case fileServerHTTPError(code: Int, message: Any?)

        internal var errorDescription: String? {
           switch self {
           case .symmetricKeyGenerationFailed: return "Couldn't generate symmetric key."
           case .endpointParsingFailed: return "Couldn't parse endpoint."
           case .proxyResponseParsingFailed: return "Couldn't parse file server proxy response."
           case .fileServerHTTPError(let httpStatusCode, let message): return "File server returned \(httpStatusCode) with description: \(message ?? "no description provided.")."
           }
        }
    }

    // MARK: Initialization
    internal init(for server: String) {
        self.server = server
        super.init()
    }

    // MARK: Proxying
    override internal func perform(_ request: TSRequest, withCompletionQueue queue: DispatchQueue = DispatchQueue.main) -> SnodeAPI.RawResponsePromise {
        let isLokiFileServer = (server == FileServerAPI.server)
        guard isLokiFileServer else { return super.perform(request, withCompletionQueue: queue) } // Don't proxy open group requests for now
        return performLokiFileServerNSURLRequest(request, withCompletionQueue: queue)
    }
    
    internal func performLokiFileServerNSURLRequest(_ request: NSURLRequest, withCompletionQueue queue: DispatchQueue = DispatchQueue.main) -> SnodeAPI.RawResponsePromise {
        var headers = getCanonicalHeaders(for: request)
        return Promise<SnodeAPI.RawResponse> { [server = self.server, keyPair = self.keyPair, httpSession = self.httpSession] seal in
            DispatchQueue.global(qos: .userInitiated).async {
                let uncheckedSymmetricKey = try? Curve25519.generateSharedSecret(fromPublicKey: LokiFileServerProxy.fileServerPublicKey, privateKey: keyPair.privateKey)
                guard let symmetricKey = uncheckedSymmetricKey else { return seal.reject(Error.symmetricKeyGenerationFailed) }
                SnodeAPI.getRandomSnode().then2 { proxy -> Promise<Any> in
                    let url = "\(proxy.address):\(proxy.port)/file_proxy"
                    guard let urlAsString = request.url?.absoluteString, let serverURLEndIndex = urlAsString.range(of: server)?.upperBound,
                        serverURLEndIndex < urlAsString.endIndex else { throw Error.endpointParsingFailed }
                    let endpointStartIndex = urlAsString.index(after: serverURLEndIndex)
                    let endpoint = String(urlAsString[endpointStartIndex..<urlAsString.endIndex])
                    let parametersAsString: String
                    if let tsRequest = request as? TSRequest {
                        headers["Content-Type"] = "application/json"
                        let parametersAsData = try JSONSerialization.data(withJSONObject: tsRequest.parameters, options: [ .fragmentsAllowed ])
                        parametersAsString = !tsRequest.parameters.isEmpty ? String(bytes: parametersAsData, encoding: .utf8)! : "null"
                    } else {
                        headers["Content-Type"] = request.allHTTPHeaderFields!["Content-Type"]
                        if let parametersAsInputStream = request.httpBodyStream, let parametersAsData = try? Data(from: parametersAsInputStream) {
                            parametersAsString = "{ \"fileUpload\" : \"\(String(data: parametersAsData.base64EncodedData(), encoding: .utf8) ?? "null")\" }"
                        } else {
                            parametersAsString = "null"
                        }
                    }
                    let proxyRequestParameters: JSON = [
                        "body" : parametersAsString,
                        "endpoint": endpoint,
                        "method" : request.httpMethod,
                        "headers" : headers
                    ]
                    let proxyRequestParametersAsData = try JSONSerialization.data(withJSONObject: proxyRequestParameters, options: [ .fragmentsAllowed ])
                    let ivAndCipherText = try DiffieHellman.encrypt(proxyRequestParametersAsData, using: symmetricKey)
                    let base64EncodedPublicKey = Data(hex: keyPair.hexEncodedPublicKey).base64EncodedString() // The file server expects an 05 prefixed public key
                    let proxyRequestHeaders = [
                        "X-Loki-File-Server-Target" : "/loki/v1/secure_rpc",
                        "X-Loki-File-Server-Verb" : "POST",
                        "X-Loki-File-Server-Headers" : "{ \"X-Loki-File-Server-Ephemeral-Key\" : \"\(base64EncodedPublicKey)\" }",
                        "Connection" : "close", // TODO: Is this necessary?
                        "Content-Type" : "application/json"
                    ]
                    let (promise, resolver) = SnodeAPI.RawResponsePromise.pending()
                    let proxyRequest = AFHTTPRequestSerializer().request(withMethod: "POST", urlString: url, parameters: nil, error: nil)
                    proxyRequest.allHTTPHeaderFields = proxyRequestHeaders
                    proxyRequest.httpBody = "{ \"cipherText64\" : \"\(ivAndCipherText.base64EncodedString())\" }".data(using: String.Encoding.utf8)!
                    proxyRequest.timeoutInterval = request.timeoutInterval
                    var task: URLSessionDataTask!
                    task = httpSession.dataTask(with: proxyRequest as URLRequest) { response, result, error in
                        if let error = error {
                            let nmError = NetworkManagerError.taskError(task: task, underlyingError: error)
                            let nsError: NSError = nmError as NSError
                            nsError.isRetryable = false
                            resolver.reject(nsError)
                        } else {
                            resolver.fulfill(result)
                        }
                    }
                    task.resume()
                    return promise
                }.map2 { rawResponse in
                    guard let responseAsData = rawResponse as? Data, let responseAsJSON = try? JSONSerialization.jsonObject(with: responseAsData, options: [ .fragmentsAllowed ]) as? JSON, let base64EncodedCipherText = responseAsJSON["data"] as? String,
                        let meta = responseAsJSON["meta"] as? JSON, let statusCode = meta["code"] as? Int, let cipherText = Data(base64Encoded: base64EncodedCipherText) else {
                        print("[Loki] Received an invalid response.")
                        throw Error.proxyResponseParsingFailed
                    }
                    let isSuccess = (200...299) ~= statusCode
                    guard isSuccess else { throw HTTPError.networkError(code: statusCode, response: nil, underlyingError: Error.fileServerHTTPError(code: statusCode, message: nil)) }
                    let uncheckedJSONAsData = try DiffieHellman.decrypt(cipherText, using: symmetricKey)
                    if uncheckedJSONAsData.isEmpty { return () }
                    let uncheckedJSON = try? JSONSerialization.jsonObject(with: uncheckedJSONAsData, options: [ .fragmentsAllowed ]) as? JSON
                    guard let json = uncheckedJSON else { throw HTTPError.networkError(code: -1, response: nil, underlyingError: Error.proxyResponseParsingFailed) }
                    return json
                }.done2 { rawResponse in
                    seal.fulfill(rawResponse)
                }.catch2 { error in
                    print("[Loki] File server proxy request failed with error: \(error.localizedDescription).")
                    seal.reject(HTTPError.from(error: error) ?? error)
                }
            }
        }
    }
}
