
public enum GroupUtilities {

    public static func getClosedGroupMembers(_ closedGroup: TSGroupThread) -> [String] {
        var result: [String]!
        Storage.read { transaction in
            result = getClosedGroupMembers(closedGroup, with: transaction)
        }
        return result
    }

    public static func getClosedGroupMembers(_ closedGroup: TSGroupThread, with transaction: YapDatabaseReadTransaction) -> [String] {
        let storage = OWSPrimaryStorage.shared()
        let userHexEncodedPublicKey = getUserHexEncodedPublicKey()
        return closedGroup.groupModel.groupMemberIds.filter { member in
            // Don't show any slave devices
            return storage.getMasterHexEncodedPublicKey(for: member, in: transaction) == nil
        }
    }

    public static func getClosedGroupMemberCount(_ closedGroup: TSGroupThread) -> Int {
        return getClosedGroupMembers(closedGroup).count
    }

    public static func getClosedGroupMemberCount(_ closedGroup: TSGroupThread, with transaction: YapDatabaseReadTransaction) -> Int {
        return getClosedGroupMembers(closedGroup, with: transaction).count
    }
}
