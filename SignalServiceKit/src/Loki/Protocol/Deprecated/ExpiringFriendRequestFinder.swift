
/*
 This class is used for finding friend request messages which are pending expiration.
 Modeled after `OWSDisappearingMessagesFinder`.
 */
@objc(LKExpiringFriendRequestFinder)
public final class ExpiringFriendRequestFinder : NSObject {
    
    private static let friendRequestExpireColumn = "friend_request_expires_at"
    private static let friendRequestExpireIndex = "loki_index_friend_request_expires_at"
    
    public func nextExpirationTimestamp(with transaction: YapDatabaseReadTransaction) -> UInt64? {
        let query = "WHERE \(ExpiringFriendRequestFinder.friendRequestExpireColumn) > 0 ORDER BY \(ExpiringFriendRequestFinder.friendRequestExpireColumn) ASC"
        
        let dbQuery = YapDatabaseQuery(string: query, parameters: [])
        let ext = transaction.ext(ExpiringFriendRequestFinder.friendRequestExpireIndex) as? YapDatabaseSecondaryIndexTransaction
        var firstMessage: TSMessage? = nil
        ext?.enumerateKeysAndObjects(matching: dbQuery) { (collection, key, object, stop) in
            firstMessage = object as? TSMessage
            stop.pointee = true
        }
        
        guard let expireTime = firstMessage?.friendRequestExpiresAt, expireTime > 0 else { return nil }
        
        return expireTime
    }
    
    public func enumurateMessagesPendingExpiration(with block: (TSMessage) -> Void, transaction: YapDatabaseReadTransaction) {
        for messageId in fetchMessagePendingExpirationIds(with: transaction) {
            guard let message = TSMessage.fetch(uniqueId: messageId, transaction: transaction) else { continue }
            block(message)
        }
    }
    
    private func fetchMessagePendingExpirationIds(with transaction: YapDatabaseReadTransaction) -> [String] {
        var messageIds = [String]()
        let now = NSDate.ows_millisecondTimeStamp()

        let query = "WHERE \(ExpiringFriendRequestFinder.friendRequestExpireColumn) > 0 AND \(ExpiringFriendRequestFinder.friendRequestExpireColumn) <= \(now)"
        // When (friendRequestExpiresAt == 0) then the friend request SHOULD NOT be set to expired
        let dbQuery = YapDatabaseQuery(string: query, parameters: [])
        if let ext = transaction.ext(ExpiringFriendRequestFinder.friendRequestExpireIndex) as? YapDatabaseSecondaryIndexTransaction {
            ext.enumerateKeys(matching: dbQuery) { (_, key, _) in
                messageIds.append(key)
            }
        }

        return Array(messageIds)
    }
    
}

// MARK: Database Extension

public extension ExpiringFriendRequestFinder {
    
    @objc public static var indexDatabaseExtension: YapDatabaseSecondaryIndex {
        let setup = YapDatabaseSecondaryIndexSetup()
        setup.addColumn(friendRequestExpireColumn, with: .integer)
        
        let handler = YapDatabaseSecondaryIndexHandler.withObjectBlock { (transaction, dict, collection, key, object) in
            guard let message = object as? TSMessage else { return }
            
            // Only select sent friend requests which are pending
            guard message is TSOutgoingMessage && message.friendRequestStatus == .pending else { return }
            
            dict[friendRequestExpireColumn] = message.friendRequestExpiresAt
        }
        
        return YapDatabaseSecondaryIndex(setup: setup, handler: handler)
    }
    
    @objc public static var databaseExtensionName: String {
        return friendRequestExpireIndex
    }
    
    @objc public static func asyncRegisterDatabaseExtensions(_ storage: OWSStorage) {
        storage.register(indexDatabaseExtension, withName: friendRequestExpireIndex)
    }
}

