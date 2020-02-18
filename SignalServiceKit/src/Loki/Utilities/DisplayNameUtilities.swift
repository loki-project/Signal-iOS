
// MARK: - User Display Name Utilities

@objc(LKUserDisplayNameUtilities)
public final class UserDisplayNameUtilities : NSObject {
    
    override private init() { }
    
    private static var userHexEncodedPublicKey: String {
        return getUserHexEncodedPublicKey()
    }
    
    private static var userDisplayName: String? {
        return SSKEnvironment.shared.profileManager.localProfileName()
    }
    
    // MARK: Sessions
    @objc public static func getPrivateChatDisplayName(for hexEncodedPublicKey: String) -> String? {
        if hexEncodedPublicKey == userHexEncodedPublicKey {
            return userDisplayName
        } else {
            return SSKEnvironment.shared.profileManager.profileName(forRecipientId: hexEncodedPublicKey)
        }
    }
    
    // MARK: Open Groups
    @objc public static func getPublicChatDisplayName(for hexEncodedPublicKey: String, in channel: UInt64, on server: String) -> String? {
        var result: String?
        Storage.read { transaction in
            result = getPublicChatDisplayName(for: hexEncodedPublicKey, in: channel, on: server, using: transaction)
        }
        return result
    }
    
    @objc public static func getPublicChatDisplayName(for hexEncodedPublicKey: String, in channel: UInt64, on server: String, using transaction: YapDatabaseReadTransaction) -> String? {
        if hexEncodedPublicKey == userHexEncodedPublicKey {
            return userDisplayName
        } else {
            let collection = "\(server).\(channel)"
            return transaction.object(forKey: hexEncodedPublicKey, inCollection: collection) as! String?
        }
    }
}

// MARK: - Group Display Name Utilities

@objc(LKGroupDisplayNameUtilities)
public final class GroupDisplayNameUtilities : NSObject {
    
    override private init() { }
    
    // MARK: Closed Groups
    @objc public static func getDefaultDisplayName(for group: TSGroupThread) -> String {
        let members = group.groupModel.groupMemberIds
        let displayNames = members.map { hexEncodedPublicKey -> String in
            guard let displayName = UserDisplayNameUtilities.getPrivateChatDisplayName(for: hexEncodedPublicKey) else { return hexEncodedPublicKey }
            let regex = try! NSRegularExpression(pattern: ".* \\(\\.\\.\\.[0-9a-fA-F]*\\)")
            guard regex.hasMatch(input: displayName) else { return displayName }
            return String(displayName[displayName.startIndex..<(displayName.index(displayName.endIndex, offsetBy: -14))])
        }.sorted()
        return displayNames.joined(separator: ", ")
    }
}
