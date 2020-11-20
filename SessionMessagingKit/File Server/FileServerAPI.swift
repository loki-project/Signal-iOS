import AFNetworking
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit

@objc(SNFileServerAPI)
public final class FileServerAPI : DotNetAPI {

    // MARK: Settings
    private static let attachmentType = "net.app.core.oembed"
    private static let deviceLinkType = "network.loki.messenger.devicemapping"
    
    internal static let publicKey = "62509D59BDEEC404DD0D489C1E15BA8F94FD3D619B01C1BF48A9922BFCB7311C"

    public static let maxFileSize = 10_000_000 // 10 MB
    /// The file server has a file size limit of `maxFileSize`, which the Service Nodes try to enforce as well. However, the limit applied by the Service Nodes
    /// is on the **HTTP request** and not the actual file size. Because the file server expects the file data to be base 64 encoded, the size of the HTTP
    /// request for a given file will be at least `ceil(n / 3) * 4` bytes, where n is the file size in bytes. This is the minimum size because there might also
    /// be other parameters in the request. On average the multiplier appears to be about 1.5, so when checking whether the file will exceed the file size limit when
    /// uploading a file we just divide the size of the file by this number. The alternative would be to actually check the size of the HTTP request but that's only
    /// possible after proof of work has been calculated and the onion request encryption has happened, which takes several seconds.
    public static let fileSizeORMultiplier: Double = 2

    @objc public static let server = "https://file.getsession.org"
    @objc public static let fileStorageBucketURL = "https://file-static.lokinet.org"
    
    // MARK: Profile Pictures
    @objc(uploadProfilePicture:)
    public static func objc_uploadProfilePicture(_ profilePicture: Data) -> AnyPromise {
        return AnyPromise.from(uploadProfilePicture(profilePicture))
    }

    public static func uploadProfilePicture(_ profilePicture: Data) -> Promise<String> {
        guard Double(profilePicture.count) < Double(maxFileSize) / fileSizeORMultiplier else { return Promise(error: Error.maxFileSizeExceeded) }
        let url = "\(server)/files"
        let parameters: JSON = [ "type" : attachmentType, "Content-Type" : "application/binary" ]
        var error: NSError?
        let request = AFHTTPRequestSerializer().multipartFormRequest(withMethod: "POST", urlString: url, parameters: parameters, constructingBodyWith: { formData in
            formData.appendPart(withFileData: profilePicture, name: "content", fileName: UUID().uuidString, mimeType: "application/binary")
        }, error: &error)
        // Uploads to the Loki File Server shouldn't include any personally identifiable information so use a dummy auth token
        request.addValue("Bearer loki", forHTTPHeaderField: "Authorization")
        if let error = error {
            SNLog("Couldn't upload profile picture due to error: \(error).")
            return Promise(error: error)
        }
        return OnionRequestAPI.sendOnionRequest(request, to: server, using: publicKey).map(on: DispatchQueue.global(qos: .userInitiated)) { json in
            guard let data = json["data"] as? JSON, let downloadURL = data["url"] as? String else {
                SNLog("Couldn't parse profile picture from: \(json).")
                throw Error.parsingFailed
            }
            Configuration.shared.storage.setLastProfilePictureUploadDate(Date())
            return downloadURL
        }
    }
    
    // MARK: Open Group Server Public Key
    public static func getPublicKey(for openGroupServer: String) -> Promise<String> {
        let url = URL(string: "\(server)/loki/v1/getOpenGroupKey/\(URL(string: openGroupServer)!.host!)")!
        let request = TSRequest(url: url)
        let token = "loki" // Tokenless request; use a dummy token
        request.allHTTPHeaderFields = [ "Content-Type" : "application/json", "Authorization" : "Bearer \(token)" ]
        return OnionRequestAPI.sendOnionRequest(request, to: server, using: publicKey).map(on: DispatchQueue.global(qos: .userInitiated)) { json in
            guard let bodyAsString = json["data"] as? String, let bodyAsData = bodyAsString.data(using: .utf8),
                let body = try JSONSerialization.jsonObject(with: bodyAsData, options: [ .fragmentsAllowed ]) as? JSON else { throw HTTP.Error.invalidJSON }
            guard let base64EncodedPublicKey = body["data"] as? String else {
                SNLog("Couldn't parse open group public key from: \(body).")
                throw Error.parsingFailed
            }
            let prefixedPublicKey = Data(base64Encoded: base64EncodedPublicKey)!
            let hexEncodedPrefixedPublicKey = prefixedPublicKey.toHexString()
            return hexEncodedPrefixedPublicKey.removing05PrefixIfNeeded()
        }
    }
}
