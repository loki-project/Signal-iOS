import PromiseKit

@objc(LKPushNotificationManager)
public final class LokiPushNotificationManager : NSObject {

    // MARK: Settings
    #if DEBUG
    private static let server = "https://dev.apns.getsession.org/"
    #else
    private static let server = "https://live.apns.getsession.org/"
    #endif
    private static let tokenExpirationInterval: TimeInterval = 12 * 60 * 60

    public enum ClosedGroupOperation: String {
        case subscribe = "subscribe_closed_group"
        case unsubscribe = "unsubscribe_closed_group"
    }

    // MARK: Initialization
    private override init() { }

    // MARK: Registration
    /// Registers the user for silent push notifications (that then trigger the app
    /// into fetching messages). Only the user's device token is needed for this.
    static func register(with token: Data, isForcedUpdate: Bool) -> Promise<Void> {
        let hexEncodedToken = token.toHexString()
        let userDefaults = UserDefaults.standard
        let oldToken = userDefaults[.deviceToken]
        let lastUploadTime = userDefaults[.lastDeviceTokenUpload]
        let isUsingFullAPNs = userDefaults[.isUsingFullAPNs]
        let now = Date().timeIntervalSince1970
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            print("[Loki] Device token hasn't changed or expired; no need to re-upload.")
            return Promise<Void> { $0.fulfill(()) }
        }
        let parameters = [ "token" : hexEncodedToken ]
        let url = URL(string: server + "register")!
        let request = TSRequest(url: url, method: "POST", parameters: parameters)
        request.allHTTPHeaderFields = [ "Content-Type" : "application/json" ]
        let promise = TSNetworkManager.shared().makePromise(request: request).map2 { _, response in
            guard let json = response as? JSON else {
                return print("[Loki] Couldn't register device token.")
            }
            guard json["code"] as? Int != 0 else {
                return print("[Loki] Couldn't register device token due to error: \(json["message"] as? String ?? "nil").")
            }
            userDefaults[.deviceToken] = hexEncodedToken
            userDefaults[.lastDeviceTokenUpload] = now
            userDefaults[.isUsingFullAPNs] = false
            return
        }
        promise.catch2 { error in
            print("[Loki] Couldn't register device token.")
        }
        // Unsubscribe from all closed groups
        Storage.getUserClosedGroupPublicKeys().forEach { closedGroup in
            performOperation(.unsubscribe, for: closedGroup, publicKey: getUserHexEncodedPublicKey())
        }
        return promise
    }

    /// Registers the user for silent push notifications (that then trigger the app
    /// into fetching messages). Only the user's device token is needed for this.
    @objc(registerWithToken:isForcedUpdate:)
    static func objc_register(with token: Data, isForcedUpdate: Bool) -> AnyPromise {
        return AnyPromise.from(register(with: token, isForcedUpdate: isForcedUpdate))
    }

    /// Registers the user for normal push notifications. Requires the user's device
    /// token and their Session ID.
    static func register(with token: Data, publicKey: String, isForcedUpdate: Bool) -> Promise<Void> {
        let hexEncodedToken = token.toHexString()
        let userDefaults = UserDefaults.standard
        let oldToken = userDefaults[.deviceToken]
        let lastUploadTime = userDefaults[.lastDeviceTokenUpload]
        let now = Date().timeIntervalSince1970
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            print("[Loki] Device token hasn't changed or expired; no need to re-upload.")
            return Promise<Void> { $0.fulfill(()) }
        }
        let parameters = [ "token" : hexEncodedToken, "pubKey" : publicKey]
        let url = URL(string: server + "register")!
        let request = TSRequest(url: url, method: "POST", parameters: parameters)
        request.allHTTPHeaderFields = [ "Content-Type" : "application/json" ]
        let promise = TSNetworkManager.shared().makePromise(request: request).map2 { _, response in
            guard let json = response as? JSON else {
                return print("[Loki] Couldn't register device token.")
            }
            guard json["code"] as? Int != 0 else {
                return print("[Loki] Couldn't register device token due to error: \(json["message"] as? String ?? "nil").")
            }
            userDefaults[.deviceToken] = hexEncodedToken
            userDefaults[.lastDeviceTokenUpload] = now
            userDefaults[.isUsingFullAPNs] = true
            return
        }
        promise.catch2 { error in
            print("[Loki] Couldn't register device token.")
        }
        // Subscribe to all closed groups
        Storage.getUserClosedGroupPublicKeys().forEach { closedGroup in
            performOperation(.subscribe, for: closedGroup, publicKey: publicKey)
        }
        return promise
    }

    /// Registers the user for normal push notifications. Requires the user's device
    /// token and their Session ID.
    @objc(registerWithToken:hexEncodedPublicKey:isForcedUpdate:)
    static func objc_register(with token: Data, publicKey: String, isForcedUpdate: Bool) -> AnyPromise {
        return AnyPromise.from(register(with: token, publicKey: publicKey, isForcedUpdate: isForcedUpdate))
    }
    
    @objc(acknowledgeDeliveryForMessageWithHash:expiration:hexEncodedPublicKey:)
    static func acknowledgeDelivery(forMessageWithHash hash: String, expiration: UInt64, publicKey: String) {
        guard UserDefaults.standard[.isUsingFullAPNs] else { return }
        let parameters: JSON = [ "lastHash" : hash, "pubKey" : publicKey, "expiration" : expiration]
        let url = URL(string: server + "acknowledge_message_delivery")!
        let request = TSRequest(url: url, method: "POST", parameters: parameters)
        request.allHTTPHeaderFields = [ "Content-Type" : "application/json" ]
        TSNetworkManager.shared().makeRequest(request, success: { _, response in
            guard let json = response as? JSON else {
                return print("[Loki] Couldn't acknowledge delivery for message with hash: \(hash).")
            }
            guard json["code"] as? Int != 0 else {
                return print("[Loki] Couldn't acknowledge delivery for message with hash: \(hash) due to error: \(json["message"] as? String ?? "nil").")
            }
        }, failure: { _, error in
            print("[Loki] Couldn't acknowledge delivery for message with hash: \(hash) due to error: \(error).")
        })
    }
    
    static func performOperation(_ operation: ClosedGroupOperation, for closedGroupPublicKey: String, publicKey: String) -> Promise<Void> {
        let isUsingFullAPNs = UserDefaults.standard[.isUsingFullAPNs]
        guard isUsingFullAPNs else { return Promise<Void> { $0.fulfill(()) } }
        let parameters = [ "closedGroupPublicKey" : closedGroupPublicKey, "pubKey" : publicKey]
        let url = URL(string: server + operation.rawValue)!
        let request = TSRequest(url: url, method: "POST", parameters: parameters)
        request.allHTTPHeaderFields = [ "Content-Type" : "application/json" ]
        let promise = TSNetworkManager.shared().makePromise(request: request).map2 { _, response in
            guard let json = response as? JSON else {
                return print("[Loki] Couldn't subscribe to PNs for closed group with ID: \(closedGroupPublicKey).")
            }
            guard json["code"] as? Int != 0 else {
                return print("[Loki] Couldn't subscribe to PNs for closed group with ID: \(closedGroupPublicKey) due to error: \(json["message"] as? String ?? "nil").")
            }
            return
        }
        promise.catch2 { error in
            print("[Loki] Couldn't subscribe to PNs for closed group with ID: \(closedGroupPublicKey).")
        }
        return promise
    }
}
