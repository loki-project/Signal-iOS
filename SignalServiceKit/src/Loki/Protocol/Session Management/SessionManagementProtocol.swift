import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • For write transactions, consider making it the caller's responsibility to manage the database transaction (this helps avoid unnecessary transactions).
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
        guard storage.currentSignedPrekeyId() == nil else { return }
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

    @objc(isSessionRequiredForMessage:)
    public static func isSessionRequired(for message: TSOutgoingMessage) -> Bool {
        if message is FriendRequestMessage { return false }
        else if message is SessionRequestMessage { return false }
        else if message is SessionRestoreMessage { return false } // TODO: Remove this after ditching session restore message
        else if let message = message as? DeviceLinkMessage, message.kind == .request { return false }
        else if (message.thread as? TSGroupThread)?.usesSharedSenderKeys == true { return false }
        return true
    }

    @objc(shouldUseFallbackEncryptionForMessage:)
    public static func shouldUseFallbackEncryption(for message: TSOutgoingMessage) -> Bool {
        return !isSessionRequired(for: message)
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

    // MARK: - Sending

    public static func establishSessionIfNeeded(with publicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        // It's never necessary to establish a session with self
        guard publicKey != getUserHexEncodedPublicKey() else { return }
        // Check that we don't already have a session
        let hasSession = storage.containsSession(publicKey, deviceId: Int32(OWSDevicePrimaryDeviceId), protocolContext: transaction)
        guard !hasSession else { return }
        // Check that we didn't already send a session request
        var hasSentSessionRequest = false
        storage.dbReadConnection.read { transaction in
            hasSentSessionRequest = storage.getSessionRequestTimestamp(for: publicKey, in: transaction) != nil
        }
        guard !hasSentSessionRequest else { return }
        // Create the thread if needed
        let thread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        thread.save(with: transaction)
        // Send the session request
        print("[Loki] Sending session request to: \(publicKey).")
        storage.setSessionRequestTimestamp(for: publicKey, to: Date(), in: transaction)
        let sessionRequestMessage = SessionRequestMessage(thread: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: sessionRequestMessage, transaction: transaction)
    }

    @objc(sendSessionEstablishedMessageToPublicKey:transaction:)
    public static func sendSessionEstablishedMessage(to publicKey: String, in transaction: YapDatabaseReadWriteTransaction) {
        let thread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        thread.save(with: transaction)
        let ephemeralMessage = EphemeralMessage(thread: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: ephemeralMessage, transaction: transaction)
    }

    /// DEPRECATED.
    ///
    /// Only relevant for closed groups that don't use shared sender keys.
    @objc(shouldIgnoreMissingPreKeyBundleExceptionForMessage:to:)
    public static func shouldIgnoreMissingPreKeyBundleException(for message: TSOutgoingMessage, to hexEncodedPublicKey: String) -> Bool {
        // When a closed group is created, members try to establish sessions with eachother in the background through
        // session requests. Until ALL users those session requests were sent to have come online, stored the pre key
        // bundles contained in the session requests and replied with background messages to finalize the session
        // creation, a given user won't be able to successfully send a message to all members of a group. This check
        // is so that until we can do better on this front the user at least won't see this as an error in the UI.
        guard let groupThread = message.thread as? TSGroupThread else { return false }
        return groupThread.groupModel.groupType == .closedGroup && !groupThread.usesSharedSenderKeys
    }

    @objc(startSessionResetInThread:transaction:)
    public static func startSessionReset(in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        // Check preconditions
        guard let thread = thread as? TSContactThread else {
            return print("[Loki] Can't restore session for non contact thread.")
        }
        // Send session restoration request messages to the devices requiring session restoration
        let devices = thread.sessionRestoreDevices // TODO: Rename this to something that reads better
        for device in devices {
            guard ECKeyPair.isValidHexEncodedPublicKey(candidate: device) else { continue }
            let thread = TSContactThread.getOrCreateThread(withContactId: device, transaction: transaction)
            thread.save(with: transaction)
            let sessionRestorationRequestMessage = SessionRestoreMessage(thread: thread)
            let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
            messageSenderJobQueue.add(message: sessionRestorationRequestMessage, transaction: transaction)
        }
        thread.removeAllSessionRestoreDevices(with: transaction)
        // Notify the user
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeLokiSessionResetInProgress)
        infoMessage.save(with: transaction)
        // Update the session reset status
        thread.sessionResetStatus = .initiated
        thread.save(with: transaction)
    }
    
    // MARK: - Session Reset
    
    public static func sendSessionRequestIfNeeded(in thread: TSContactThread, using transaction: YapDatabaseReadWriteTransaction) {
        let hasSession = storage.containsSession(thread.contactIdentifier(), deviceId: Int32(OWSDevicePrimaryDeviceId), protocolContext: transaction)
        guard !hasSession && thread.sessionResetStatus == .none else { return }
        // TODO: send session request
    }

    // MARK: - Receiving
    
    @objc(handleDecryptionError:forPublicKey:transaction:)
    public static func handleDecryptionError(_ rawValue: Int32, for publicKey: String, using transaction: YapDatabaseReadWriteTransaction) {
        let type = TSErrorMessageType(rawValue: rawValue)
        let thread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        // Move session reset progress to background
        switch type {
        case .noSession, .invalidMessage, .invalidKeyException:
            if (thread.sessionResetStatus == .none) {
                // Store the source device's public key in case it was a secondary device
                thread.addSessionRestoreDevice(publicKey, transaction: transaction)
            }
            // TODO: should move to this
            // sendSessionRequestIfNeeded(in: thread, using: transaction)
        default: break
        }
    }

    @objc(handlePreKeyBundleMessageIfNeeded:wrappedIn:transaction:)
    public static func handlePreKeyBundleMessageIfNeeded(_ protoContent: SSKProtoContent, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        let publicKey = envelope.source! // Set during UD decryption
        guard let preKeyBundleMessage = protoContent.prekeyBundleMessage else { return }
        print("[Loki] Received a pre key bundle message from: \(publicKey).")
        guard let preKeyBundle = preKeyBundleMessage.getPreKeyBundle(with: transaction) else {
            return print("[Loki] Couldn't parse pre key bundle received from: \(publicKey).")
        }
        if isSessionRequestMessage(protoContent.dataMessage),
            let sentSessionRequestTimestamp = storage.getSessionRequestTimestamp(for: publicKey, in: transaction),
            envelope.timestamp < NSDate.ows_millisecondsSince1970(for: sentSessionRequestTimestamp) {
            // We sent a session request after this one was sent
            return print("[Loki] Ignoring session request from: \(publicKey).")
        }
        storage.setPreKeyBundle(preKeyBundle, forContact: publicKey, transaction: transaction)
    }

    /// - Note: Must be invoked after `handlePreKeyBundleMessageIfNeeded(_:wrappedIn:using:)`.
    @objc(handleSessionRequestMessageIfNeeded:wrappedIn:transaction:)
    public static func handleSessionRequestMessageIfNeeded(_ protoContent: SSKProtoContent, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) -> Bool {
        guard isSessionRequestMessage(protoContent.dataMessage) else { return false }
        let publicKey = envelope.source! // Set during UD decryption
        if let sentSessionRequestTimestamp = storage.getSessionRequestTimestamp(for: publicKey, in: transaction),
            envelope.timestamp < NSDate.ows_millisecondsSince1970(for: sentSessionRequestTimestamp) {
            // We sent a session request after this one was sent
            print("[Loki] Ignoring session request from: \(publicKey).")
            return false
        }
        sendSessionEstablishedMessage(to: publicKey, in: transaction)
        return true
    }

    @objc(handleEndSessionMessageReceivedInThread:using:)
    public static func handleEndSessionMessageReceived(in thread: TSContactThread, using transaction: YapDatabaseReadWriteTransaction) {
        let publicKey = thread.contactIdentifier()
        print("[Loki] End session message received from: \(publicKey).")
        // Notify the user
        // Make sure the info message is shown in the master thread
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
