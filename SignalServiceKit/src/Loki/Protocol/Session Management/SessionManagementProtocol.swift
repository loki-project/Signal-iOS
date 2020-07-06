import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • Consider making it the caller's responsibility to manage the database transaction (this helps avoid unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.
// • Document the expected cases in which a function will be used
// • Express those cases in tests.

@objc(LKSessionManagementProtocol)
public final class SessionManagementProtocol : NSObject {

    internal static var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }

    // MARK: - General
    @objc(createPreKeys)
    public static func createPreKeys() {
        // We don't generate new pre keys here like Signal does.
        // This is because we need the records to be linked to a contact since we don't have a central server.
        // It's done automatically when we generate a pre key bundle to send to a contact (generatePreKeyBundleForContact:).
        // You can use getOrCreatePreKeyForContact: to generate one if needed.
        let signedPreKeyRecord = storage.generateRandomSignedRecord()
        signedPreKeyRecord.markAsAcceptedByService()
        storage.storeSignedPreKey(signedPreKeyRecord.id, signedPreKeyRecord: signedPreKeyRecord)
        storage.setCurrentSignedPrekeyId(signedPreKeyRecord.id)
        print("[Loki] Pre keys created successfully.")
    }

    @objc(refreshSignedPreKey)
    public static func refreshSignedPreKey() {
        // We don't generate new pre keys here like Signal does.
        // This is because we need the records to be linked to a contact since we don't have a central server.
        // It's done automatically when we generate a pre key bundle to send to a contact (generatePreKeyBundleForContact:).
        // You can use getOrCreatePreKeyForContact: to generate one if needed.
        guard storage.currentSignedPrekeyId() == nil else {
            print("[Loki] Skipping signed pre key refresh; using existing signed pre key.")
            return
        }
        let signedPreKeyRecord = storage.generateRandomSignedRecord()
        signedPreKeyRecord.markAsAcceptedByService()
        storage.storeSignedPreKey(signedPreKeyRecord.id, signedPreKeyRecord: signedPreKeyRecord)
        storage.setCurrentSignedPrekeyId(signedPreKeyRecord.id)
        TSPreKeyManager.clearPreKeyUpdateFailureCount()
        TSPreKeyManager.clearSignedPreKeyRecords()
        print("[Loki] Signed pre key refreshed successfully.")
    }

    @objc(rotateSignedPreKey)
    public static func rotateSignedPreKey() {
        // This is identical to what Signal does, except that it doesn't upload the signed pre key
        // to a server.
        let signedPreKeyRecord = storage.generateRandomSignedRecord()
        signedPreKeyRecord.markAsAcceptedByService()
        storage.storeSignedPreKey(signedPreKeyRecord.id, signedPreKeyRecord: signedPreKeyRecord)
        storage.setCurrentSignedPrekeyId(signedPreKeyRecord.id)
        TSPreKeyManager.clearPreKeyUpdateFailureCount()
        TSPreKeyManager.clearSignedPreKeyRecords()
        print("[Loki] Signed pre key rotated successfully.")
    }

    @objc(shouldUseFallbackEncryptionForMessage:)
    public static func shouldUseFallbackEncryption(_ message: TSOutgoingMessage) -> Bool {
        return !isSessionRequired(for: message)
    }

    @objc(isSessionRequiredForMessage:)
    public static func isSessionRequired(for message: TSOutgoingMessage) -> Bool {
        if message is FriendRequestMessage { return false }
        else if message is SessionRequestMessage { return false }
        else if let message = message as? DeviceLinkMessage, message.kind == .request { return false }
        return true
    }

    // MARK: - Sending
    @objc(startSessionResetInThread:using:)
    public static func startSessionReset(in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        guard let thread = thread as? TSContactThread else {
            print("[Loki] Can't restore session for non contact thread.")
            return
        }
        let messageSender = SSKEnvironment.shared.messageSender
        let devices = thread.sessionRestoreDevices // TODO: Rename this
        for device in devices {
            guard device.count != 0 else { continue }
            getSessionResetMessageSend(for: device, in: transaction).done(on: OWSDispatch.sendingQueue()) { sessionResetMessageSend in
                messageSender.sendMessage(sessionResetMessageSend)
            }
        }
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeLokiSessionResetInProgress)
        infoMessage.save(with: transaction)
        thread.sessionResetStatus = .initiated
        thread.save(with: transaction)
        thread.removeAllSessionRestoreDevices(with: transaction)
    }

    @objc(getSessionResetMessageForHexEncodedPublicKey:in:)
    public static func getSessionResetMessage(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> SessionRestoreMessage {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let result = SessionRestoreMessage(thread: thread)
        result.skipSave = true // TODO: Why is this necessary?
        return result
    }

    @objc(getSessionResetMessageSendForHexEncodedPublicKey:in:)
    public static func objc_getSessionResetMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> AnyPromise {
        return AnyPromise.from(getSessionResetMessageSend(for: hexEncodedPublicKey, in: transaction))
    }

    public static func getSessionResetMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> Promise<OWSMessageSend> {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let message = getSessionResetMessage(for: hexEncodedPublicKey, in: transaction)
        let recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: hexEncodedPublicKey, transaction: transaction)
        let udManager = SSKEnvironment.shared.udManager
        let senderCertificate = udManager.getSenderCertificate()
        let (promise, seal) = Promise<OWSMessageSend>.pending()
        var recipientUDAccess: OWSUDAccess?
        if let senderCertificate = senderCertificate {
            SSKEnvironment.shared.profileManager.ensureProfileCachedForContact(withID: hexEncodedPublicKey, with: transaction) // Prevent the line below from starting a write transaction
            recipientUDAccess = udManager.udAccess(forRecipientId: hexEncodedPublicKey, requireSyncAccess: true)
        }
        let messageSend = OWSMessageSend(message: message, thread: thread, recipient: recipient, senderCertificate: senderCertificate,
            udAccess: recipientUDAccess, localNumber: getUserHexEncodedPublicKey(), success: {

        }, failure: { error in

        })
        seal.fulfill(messageSend)
        return promise
    }

    @objc(repairSessionIfNeededForMessage:to:)
    public static func repairSessionIfNeeded(for message: TSOutgoingMessage, to hexEncodedPublicKey: String) {
        guard (message.thread as? TSGroupThread)?.groupModel.groupType == .closedGroup else { return }
        var hasSentSessionRequest = false
        storage.dbReadConnection.read { transaction in
            hasSentSessionRequest = storage.getSessionRequestTimestamp(for: hexEncodedPublicKey, in: transaction) != nil
        }
        guard !hasSentSessionRequest else { return }
        Storage.write { transaction in
            print("[Loki] Repairing session with: \(hexEncodedPublicKey).")
            let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
            let sessionRequestMessage = SessionRequestMessage(thread: thread)
            storage.setSessionRequestTimestamp(for: hexEncodedPublicKey, to: Date(), in: transaction)
            let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
            messageSenderJobQueue.add(message: sessionRequestMessage, transaction: transaction)
        }
    }

    @objc(shouldIgnoreMissingPreKeyBundleExceptionForMessage:to:)
    public static func shouldIgnoreMissingPreKeyBundleException(for message: TSOutgoingMessage, to hexEncodedPublicKey: String) -> Bool {
        // When a closed group is created, members try to establish sessions with eachother in the background through
        // session requests. Until ALL users those session requests were sent to have come online, stored the pre key
        // bundles contained in the session requests and replied with background messages to finalize the session
        // creation, a given user won't be able to successfully send a message to all members of a group. This check
        // is so that until we can do better on this front the user at least won't see this as an error in the UI.
        return (message.thread as? TSGroupThread)?.groupModel.groupType == .closedGroup
    }

    // MARK: - Receiving
    @objc(handleDecryptionError:forHexEncodedPublicKey:using:)
    public static func handleDecryptionError(_ rawValue: Int32, for hexEncodedPublicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        let type = TSErrorMessageType(rawValue: rawValue)
        let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
        let thread = TSContactThread.getOrCreateThread(withContactId: masterHexEncodedPublicKey, transaction: transaction)
        // Show the session reset prompt upon certain errors
        switch type {
        case .noSession, .invalidMessage, .invalidKeyException:
            if (thread.sessionResetStatus == .none) {
                // Store the source device's public key in case it was a secondary device
                thread.addSessionRestoreDevice(hexEncodedPublicKey, transaction: transaction)
            }
        default: break
        }
    }
    
    @objc(isErrorMessageBeforeRestoration:)
    public static func isErrorMessageBeforeRestoration(_ errorMessage: TSErrorMessage) -> Bool {
        let restorationTimeInMs = UInt64(storage.getRestorationTime() * 1000)
        return errorMessage.timestamp < restorationTimeInMs
    }

    @objc(isSessionRestorationRequest:)
    public static func isSessionRestorationRequest(_ dataMessage: SSKProtoDataMessage?) -> Bool {
        guard let dataMessage = dataMessage else { return false }
        let sessionRestoreFlag = SSKProtoDataMessage.SSKProtoDataMessageFlags.sessionRestore
        return dataMessage.hasFlags && (dataMessage.flags & UInt32(sessionRestoreFlag.rawValue) != 0)
    }

    @objc(isSessionRequestMessage:)
    public static func isSessionRequestMessage(_ dataMessage: SSKProtoDataMessage?) -> Bool {
        guard let dataMessage = dataMessage else { return false }
        let sessionRequestFlag = SSKProtoDataMessage.SSKProtoDataMessageFlags.sessionRequest
        return dataMessage.hasFlags && (dataMessage.flags & UInt32(sessionRequestFlag.rawValue) != 0)
    }

    @objc(handleSessionRequestMessage:wrappedIn:using:)
    public static func handleSessionRequestMessage(_ dataMessage: SSKProtoDataMessage, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        let sender = envelope.source! // Set during UD decryption
        if let sentSessionRequestTimestamp = storage.getSessionRequestTimestamp(for: sender, in: transaction),
            envelope.timestamp < NSDate.ows_millisecondsSince1970(for: sentSessionRequestTimestamp) {
            // We sent a session request after this one was sent
            print("[Loki] Ignoring session request from: \(sender).")
            return
        }
        let thread = TSContactThread.getOrCreateThread(withContactId: sender, transaction: transaction)
        let ephemeralMessage = EphemeralMessage(thread: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: ephemeralMessage, transaction: transaction)
    }

    @objc(handlePreKeyBundleMessageIfNeeded:wrappedIn:using:)
    public static func handlePreKeyBundleMessageIfNeeded(_ protoContent: SSKProtoContent, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        let sender = envelope.source! // Set during UD decryption
        guard let preKeyBundleMessage = protoContent.prekeyBundleMessage else { return }
        print("[Loki] Received a pre key bundle message from: \(sender).")
        guard let preKeyBundle = preKeyBundleMessage.getPreKeyBundle(with: transaction) else {
            print("[Loki] Couldn't parse pre key bundle received from: \(sender).")
            return
        }
        if isSessionRequestMessage(protoContent.dataMessage),
            let sentSessionRequestTimestamp = storage.getSessionRequestTimestamp(for: sender, in: transaction),
            envelope.timestamp < NSDate.ows_millisecondsSince1970(for: sentSessionRequestTimestamp) {
            // We sent a session request after this one was sent
            print("[Loki] Ignoring session request from: \(sender).")
            return
        }
        storage.setPreKeyBundle(preKeyBundle, forContact: sender, transaction: transaction)
    }

    @objc(sendSessionEstablishedMessageToPublicKey:in:)
    public static func sendSessionEstablishedMessage(to publicKey: String, in transaction: YapDatabaseReadWriteTransaction) {
        let thread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        let ephemeralMessage = EphemeralMessage(thread: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: ephemeralMessage, transaction: transaction)
    }

    @objc(handleEndSessionMessageReceivedInThread:using:)
    public static func handleEndSessionMessageReceived(in thread: TSContactThread, using transaction: YapDatabaseReadWriteTransaction) {
        let publicKey = thread.contactIdentifier()
        print("[Loki] End session message received from: \(publicKey).")
        // Notify the user
        let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: publicKey, in: transaction) ?? publicKey
        let thread = TSContactThread.getOrCreateThread(withContactId: masterHexEncodedPublicKey, transaction: transaction)
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeLokiSessionResetInProgress)
        infoMessage.save(with: transaction)
        // Archive all sessions
        storage.archiveAllSessions(forContact: publicKey, protocolContext: transaction)
        // Update the session reset status
        thread.sessionResetStatus = .requestReceived
        thread.save(with: transaction)
        // Send an ephemeral message
        let ephemeralMessage = EphemeralMessage(thread: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: ephemeralMessage, transaction: transaction)
    }
}
