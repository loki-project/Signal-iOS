
extension AppDelegate : OpenGroupAPIDelegate {

    public func updateProfileIfNeeded(for channel: UInt64, on server: String, from info: OpenGroupInfo) {
        let storage = OWSPrimaryStorage.shared()
        let publicChatID = "\(server).\(channel)"
        Storage.writeSync { transaction in
            // Update user count
            storage.setUserCount(info.memberCount, forPublicChatWithID: publicChatID, in: transaction)
            let groupThread = TSGroupThread.getOrCreateThread(withGroupId: publicChatID.data(using: .utf8)!, groupType: .openGroup, transaction: transaction)
            // Update display name if needed
            let groupModel = groupThread.groupModel
            if groupModel.groupName != info.displayName {
                let newGroupModel = TSGroupModel(title: info.displayName, memberIds: groupModel.groupMemberIds, image: groupModel.groupImage, groupId: groupModel.groupId, groupType: groupModel.groupType, adminIds: groupModel.groupAdminIds)
                groupThread.groupModel = newGroupModel
                groupThread.save(with: transaction)
            }
            // Download and update profile picture if needed
            let oldProfilePictureURL = storage.getProfilePictureURL(forPublicChatWithID: publicChatID, in: transaction)
            if oldProfilePictureURL != info.profilePictureURL || groupModel.groupImage == nil {
                storage.setProfilePictureURL(info.profilePictureURL, forPublicChatWithID: publicChatID, in: transaction)
                if let profilePictureURL = info.profilePictureURL {
                    var sanitizedServerURL = server
                    var sanitizedProfilePictureURL = profilePictureURL
                    while sanitizedServerURL.hasSuffix("/") { sanitizedServerURL.removeLast(1) }
                    while sanitizedProfilePictureURL.hasPrefix("/") { sanitizedProfilePictureURL.removeFirst(1) }
                    let url = "\(sanitizedServerURL)/\(sanitizedProfilePictureURL)"
                    FileServerAPI.downloadAttachment(from: url).map2 { srcData in
                        let attachmentStream: TSAttachmentStream
                        let data: Data
                        if let srcImage = UIImage(data: srcData), let dstData = srcImage.jpegData(compressionQuality: 0.8) {
                            data = dstData
                        } else {
                            data = srcData
                        }
                        attachmentStream = TSAttachmentStream(contentType: OWSMimeTypeImageJpeg, byteCount: UInt32(data.count), sourceFilename: nil, caption: nil, albumMessageId: nil)
                        try attachmentStream.write(data)
                        groupThread.updateAvatar(with: attachmentStream)
                    }
                }
            }
        }
    }
}
