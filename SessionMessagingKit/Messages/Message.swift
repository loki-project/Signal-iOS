
/// Abstract base class for `VisibleMessage` and `ControlMessage`.
@objc(SNMessage)
public class Message : NSObject, NSCoding { // NSObject/NSCoding conformance is needed for YapDatabase compatibility
    public var id: String?
    public var threadID: String?
    public var sentTimestamp: UInt64?
    public var receivedTimestamp: UInt64?
    public var recipient: String?

    public class var ttl: UInt64 { 2 * 24 * 60 * 60 * 1000 }

    public override init() { }

    // MARK: Validation
    public var isValid: Bool { true }

    // MARK: Coding
    public required init?(coder: NSCoder) {
        if let id = coder.decodeObject(forKey: "id") as! String? { self.id = id }
        if let threadID = coder.decodeObject(forKey: "threadID") as! String? { self.threadID = threadID }
        if let sentTimestamp = coder.decodeObject(forKey: "sentTimestamp") as! UInt64? { self.sentTimestamp = sentTimestamp }
        if let receivedTimestamp = coder.decodeObject(forKey: "receivedTimestamp") as! UInt64? { self.receivedTimestamp = receivedTimestamp }
        if let recipient = coder.decodeObject(forKey: "recipient") as! String? { self.recipient = recipient }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id, forKey: "id")
        coder.encode(threadID, forKey: "threadID")
        coder.encode(sentTimestamp, forKey: "sentTimestamp")
        coder.encode(receivedTimestamp, forKey: "receivedTimestamp")
        coder.encode(recipient, forKey: "recipient")
    }

    // MARK: Proto Conversion
    public class func fromProto(_ proto: SNProtoContent) -> Self? {
        preconditionFailure("fromProto(_:) is abstract and must be overridden.")
    }

    public func toProto() -> SNProtoContent? {
        preconditionFailure("toProto() is abstract and must be overridden.")
    }
}
