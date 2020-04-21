import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • Consider making it the caller's responsibility to manage the database transaction (this helps avoid nested or unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.

// TODO: Document the expected cases for everything and then express those cases in tests

public final class SessionProtocol : NSObject {

    private static var _lastDeviceLinkUpdate: [String:Date] = [:]
    /// A mapping from hex encoded public key to date updated.
    public static var lastDeviceLinkUpdate: [String:Date] {
        get { LokiAPI.stateQueue.sync { _lastDeviceLinkUpdate } }
        set { LokiAPI.stateQueue.sync { _lastDeviceLinkUpdate = newValue } }
    }

    // TODO: I don't think this stateQueue stuff actually helps avoid race conditions

    private static var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }



    // MARK: - Initialization
    private override init() { }



    // MARK: - Settings
    public static let deviceLinkUpdateInterval: TimeInterval = 20



    // MARK: - Multi Device Destination
    public struct MultiDeviceDestination : Hashable {
        public let hexEncodedPublicKey: String
        public let kind: Kind

        public enum Kind : String { case master, slave }
    }



    // MARK: - Message Destination
    @objc(getDestinationsForOutgoingSyncMessage:)
    public static func getDestinations(for outgoingSyncMessage: OWSOutgoingSyncMessage) -> Set<String> {
        var result: Set<String> = []
        storage.dbReadConnection.read { transaction in
            // NOTE: Aim the message at all linked devices, including this one
            // TODO: Should we exclude the current device?
            result = LokiDatabaseUtilities.getLinkedDeviceHexEncodedPublicKeys(for: getUserHexEncodedPublicKey(), in: transaction)
        }
        return result
    }

    @objc(getDestinationsForOutgoingGroupMessage:inThread:)
    public static func getDestinations(for outgoingGroupMessage: TSOutgoingMessage, in thread: TSThread) -> Set<String> {
        guard let thread = thread as? TSGroupThread else { preconditionFailure("Can't get destinations for group message in non-group thread.") }
        var result: Set<String> = []
        if thread.isPublicChat {
            storage.dbReadConnection.read { transaction in
                if let openGroup = LokiDatabaseUtilities.getPublicChat(for: thread.uniqueId!, in: transaction) {
                    result = [ openGroup.server ] // Aim the message at the open group server
                } else {
                    // TODO: Handle
                }
            }
        } else {
            result = Set(outgoingGroupMessage.sendingRecipientIds()).intersection(thread.groupModel.groupMemberIds) // This is what Signal does

        }
        return result
    }



    // MARK: - Note to Self
    // BEHAVIOR NOTE: OWSMessageSender.sendMessageToService:senderCertificate:success:failure: aborts early and just sends
    // a sync message instead if the message it's supposed to send is considered a note to self (INCLUDING linked devices).
    // BEHAVIOR NOTE: OWSMessageSender.sendMessage: aborts early and does nothing if the message is target at
    // the current user (EXCLUDING linked devices).
    // BEHAVIOR NOTE: OWSMessageSender.handleMessageSentLocally:success:failure: doesn't send a sync transcript if the message
    // that was sent is considered a note to self (INCLUDING linked devices) but it does then mark the message as read.
    
    // TODO: Check that the behaviors described above make sense

    @objc(isMessageNoteToSelf:inThread:)
    public static func isMessageNoteToSelf(_ message: TSOutgoingMessage, in thread: TSThread) -> Bool {
        guard let thread = thread as? TSContactThread, !(message is OWSOutgoingSyncMessage) && !(message is DeviceLinkMessage) else { return false }
        var isNoteToSelf = false
        storage.dbReadConnection.read { transaction in
            isNoteToSelf = LokiDatabaseUtilities.isUserLinkedDevice(thread.contactIdentifier(), transaction: transaction)
        }
        return isNoteToSelf
    }



    // MARK: - Friend Requests
    @objc(acceptFriendRequest:in:using:)
    public static func acceptFriendRequest(_ friendRequest: TSIncomingMessage, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        // Accept all outstanding friend requests associated with this user and try to establish sessions with the
        // subset of their devices that haven't sent a friend request.
        let senderID = friendRequest.authorId
        let linkedDeviceThreads = LokiDatabaseUtilities.getLinkedDeviceThreads(for: senderID, in: transaction)
        for thread in linkedDeviceThreads {
            if thread.hasPendingFriendRequest {
                // TODO: The Obj-C implementation was actually sending this to self.thread. I'm assuming that's not what we meant.
                sendFriendRequestAcceptanceMessage(to: senderID, in: thread, using: transaction)
            } else {
                let autoGeneratedFRMessageSend = getAutoGeneratedMultiDeviceFRMessageSend(for: senderID, in: transaction)
                OWSDispatch.sendingQueue().async {
                    let messageSender = SSKEnvironment.shared.messageSender
                    messageSender.sendMessage(autoGeneratedFRMessageSend)
                }
            }
        }
        thread.saveFriendRequestStatus(.friends, with: transaction)
    }

    @objc(sendFriendRequestAcceptanceMessageToHexEncodedPublicKey:in:using:)
    public static func sendFriendRequestAcceptanceMessage(to hexEncodedPublicKey: String, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        let ephemeralMessage = EphemeralMessage(in: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: ephemeralMessage, transaction: transaction)
    }

    @objc(declineFriendRequest:in:using:)
    public static func declineFriendRequest(_ friendRequest: TSIncomingMessage, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        thread.saveFriendRequestStatus(.none, with: transaction)
        // Delete pre keys
        let senderID = friendRequest.authorId
        storage.removePreKeyBundle(forContact: senderID, transaction: transaction)
    }



    // MARK: - Multi Device
    @objc(sendMessageToDestinationAndLinkedDevices:in:)
    public static func sendMessageToDestinationAndLinkedDevices(_ messageSend: OWSMessageSend, in transaction: YapDatabaseReadWriteTransaction) {
        // TODO: I'm pretty sure there are quite a few holes in this logic
        let message = messageSend.message
        let recipientID = messageSend.recipient.recipientId()
        let thread = messageSend.thread!
        let isGroupMessage = thread.isGroupThread()
        let isOpenGroupMessage = (thread as? TSGroupThread)?.isPublicChat == true
        let isDeviceLinkMessage = message is DeviceLinkMessage
        let messageSender = SSKEnvironment.shared.messageSender
        guard !isOpenGroupMessage && !isDeviceLinkMessage else {
            return messageSender.sendMessage(messageSend)
        }
        let isSilentMessage = message.isSilent || message is EphemeralMessage || message is OWSOutgoingSyncMessage
        let isFriendRequestMessage = message is FriendRequestMessage
        let isSessionRequestMessage = message is LKSessionRequestMessage
        getMultiDeviceDestinations(for: recipientID, in: transaction).done(on: OWSDispatch.sendingQueue()) { destinations in
            // Send to master destination
            if let masterDestination = destinations.first(where: { $0.kind == .master }) {
                let thread = TSContactThread.getOrCreateThread(contactId: masterDestination.hexEncodedPublicKey) // TODO: I guess it's okay this starts a new transaction?
                if thread.isContactFriend || isSilentMessage || isFriendRequestMessage || isSessionRequestMessage || isGroupMessage {
                    let messageSendCopy = messageSend.copy(with: masterDestination)
                    messageSender.sendMessage(messageSendCopy)
                } else {
                    var frMessageSend: OWSMessageSend!
                    storage.dbReadWriteConnection.readWrite { transaction in // TODO: Yet another transaction
                        frMessageSend = getAutoGeneratedMultiDeviceFRMessageSend(for: masterDestination.hexEncodedPublicKey, in: transaction)
                    }
                    messageSender.sendMessage(frMessageSend)
                }
            }
            // Send to slave destinations (using a best attempt approach (i.e. ignoring the message send result) for now)
            let slaveDestinations = destinations.filter { $0.kind == .slave }
            for slaveDestination in slaveDestinations {
                let thread = TSContactThread.getOrCreateThread(contactId: slaveDestination.hexEncodedPublicKey) // TODO: I guess it's okay this starts a new transaction?
                if thread.isContactFriend || isSilentMessage || isFriendRequestMessage || isSessionRequestMessage || isGroupMessage {
                    let messageSendCopy = messageSend.copy(with: slaveDestination)
                    messageSender.sendMessage(messageSendCopy)
                } else {
                    var frMessageSend: OWSMessageSend!
                    storage.dbReadWriteConnection.readWrite { transaction in  // TODO: Yet another transaction
                        frMessageSend = getAutoGeneratedMultiDeviceFRMessageSend(for: slaveDestination.hexEncodedPublicKey, in: transaction)
                    }
                    messageSender.sendMessage(frMessageSend)
                }
            }
        }.catch(on: OWSDispatch.sendingQueue()) { error in
            // Proceed even if updating the linked devices map failed so that message sending
            // is independent of whether the file server is up
            messageSender.sendMessage(messageSend)
        }.retainUntilComplete()
    }

    @objc(updateDeviceLinksIfNeededForHexEncodedPublicKey:in:)
    public static func updateDeviceLinksIfNeeded(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> AnyPromise {
        let promise = getMultiDeviceDestinations(for: hexEncodedPublicKey, in: transaction)
        return AnyPromise.from(promise)
    }

    private static func getMultiDeviceDestinations(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> Promise<Set<MultiDeviceDestination>> {
        // FIXME: Threading
        let (promise, seal) = Promise<Set<MultiDeviceDestination>>.pending()
        func getDestinations(in transaction: YapDatabaseReadTransaction? = nil) {
            storage.dbReadConnection.read { transaction in
                var destinations: Set<MultiDeviceDestination> = []
                let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
                let masterDestination = MultiDeviceDestination(hexEncodedPublicKey: masterHexEncodedPublicKey, kind: .master)
                destinations.insert(masterDestination)
                let deviceLinks = storage.getDeviceLinks(for: masterHexEncodedPublicKey, in: transaction)
                let slaveDestinations = deviceLinks.map { MultiDeviceDestination(hexEncodedPublicKey: $0.slave.hexEncodedPublicKey, kind: .slave) }
                destinations.formUnion(slaveDestinations)
                seal.fulfill(destinations)
            }
        }
        let timeSinceLastUpdate: TimeInterval
        if let lastDeviceLinkUpdate = lastDeviceLinkUpdate[hexEncodedPublicKey] {
            timeSinceLastUpdate = Date().timeIntervalSince(lastDeviceLinkUpdate)
        } else {
            timeSinceLastUpdate = .infinity
        }
        if timeSinceLastUpdate > deviceLinkUpdateInterval {
            let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
            LokiFileServerAPI.getDeviceLinks(associatedWith: masterHexEncodedPublicKey, in: transaction).done(on: LokiAPI.workQueue) { _ in
                getDestinations()
                lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
            }.catch(on: LokiAPI.workQueue) { error in
                if (error as? LokiDotNetAPI.LokiDotNetAPIError) == LokiDotNetAPI.LokiDotNetAPIError.parsingFailed {
                    // Don't immediately re-fetch in case of failure due to a parsing error
                    lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
                    getDestinations()
                } else {
                    print("[Loki] Failed to get device links due to error: \(error).")
                    seal.reject(error)
                }
            }
        } else {
            getDestinations()
        }
        return promise
    }

    @objc(getAutoGeneratedMultiDeviceFRMessageForHexEncodedPublicKey:in:)
    public static func getAutoGeneratedMultiDeviceFRMessage(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> FriendRequestMessage {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction)
        let isSlaveDeviceThread = masterHexEncodedPublicKey != hexEncodedPublicKey
        thread.isForceHidden = isSlaveDeviceThread
        if thread.friendRequestStatus == .none || thread.friendRequestStatus == .requestExpired {
            thread.saveFriendRequestStatus(.requestSent, with: transaction) // TODO: Should we always immediately mark the slave device as a friend?
        }
        thread.save(with: transaction)
        let result = FriendRequestMessage(outgoingMessageWithTimestamp: NSDate.ows_millisecondTimeStamp(), in: thread,
            messageBody: "Please accept to enable messages to be synced across devices",
            attachmentIds: [], expiresInSeconds: 0, expireStartedAt: 0, isVoiceMessage: false,
            groupMetaMessage: .unspecified, quotedMessage: nil, contactShare: nil, linkPreview: nil)
        result.skipSave = true // TODO: Why is this necessary again?
        return result
    }

    @objc(getAutoGeneratedMultiDeviceFRMessageSendForHexEncodedPublicKey:in:)
    public static func getAutoGeneratedMultiDeviceFRMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> OWSMessageSend {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let message = getAutoGeneratedMultiDeviceFRMessage(for: hexEncodedPublicKey, in: transaction)
        let recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: hexEncodedPublicKey, transaction: transaction)
        let udManager = SSKEnvironment.shared.udManager
        let senderCertificate = udManager.getSenderCertificate()
        var recipientUDAccess: OWSUDAccess?
        if let senderCertificate = senderCertificate {
            recipientUDAccess = udManager.udAccess(forRecipientId: hexEncodedPublicKey, requireSyncAccess: true)
        }
        return OWSMessageSend(message: message, thread: thread, recipient: recipient, senderCertificate: senderCertificate,
            udAccess: recipientUDAccess, localNumber: getUserHexEncodedPublicKey(), success: {

        }, failure: { error in

        })
    }



    // MARK: - Session Reset
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
            let sessionResetMessageSend = getSessionResetMessageSend(for: device, in: transaction)
            OWSDispatch.sendingQueue().async {
                messageSender.sendMessage(sessionResetMessageSend)
            }
        }
        let infoMessage = TSInfoMessage(timestamp: NSDate.ows_millisecondTimeStamp(), in: thread, messageType: .typeLokiSessionResetInProgress)
        infoMessage.save(with: transaction)
        thread.sessionResetStatus = .requestReceived
        thread.save(with: transaction)
        thread.removeAllSessionRestoreDevices(with: transaction)
    }

    @objc(getSessionResetMessageForHexEncodedPublicKey:in:)
    public static func getSessionResetMessage(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> SessionRestoreMessage {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let result = SessionRestoreMessage(thread: thread)!
        result.skipSave = true // TODO: Why is this necessary again?
        return result
    }

    @objc(getSessionResetMessageSendForHexEncodedPublicKey:in:)
    public static func getSessionResetMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> OWSMessageSend {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction)
        let isSlaveDeviceThread = masterHexEncodedPublicKey != hexEncodedPublicKey
        thread.isForceHidden = isSlaveDeviceThread
        thread.save(with: transaction)
        let message = getSessionResetMessage(for: hexEncodedPublicKey, in: transaction)
        let recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: hexEncodedPublicKey, transaction: transaction)
        let udManager = SSKEnvironment.shared.udManager
        let senderCertificate = udManager.getSenderCertificate()
        var recipientUDAccess: OWSUDAccess?
        if let senderCertificate = senderCertificate {
            recipientUDAccess = udManager.udAccess(forRecipientId: hexEncodedPublicKey, requireSyncAccess: true)
        }
        return OWSMessageSend(message: message, thread: thread, recipient: recipient, senderCertificate: senderCertificate,
            udAccess: recipientUDAccess, localNumber: getUserHexEncodedPublicKey(), success: {

        }, failure: { error in

        })
    }



    // MARK: - Transcripts
    @objc(shouldSendTranscriptForMessage:in:)
    public static func shouldSendTranscript(for message: TSOutgoingMessage, in thread: TSThread) -> Bool {
        let isNoteToSelf = isMessageNoteToSelf(message, in: thread)
        let isOpenGroupMessage = (thread as? TSGroupThread)?.isPublicChat == true
        let wouldSignalRequireTranscript = (AreRecipientUpdatesEnabled() || !message.hasSyncedTranscript)
        return wouldSignalRequireTranscript && !isNoteToSelf && !isOpenGroupMessage && !(message is DeviceLinkMessage)
    }



    // MARK: - Sessions
    // BEHAVIOR NOTE: OWSMessageSender.throws_encryptedMessageForMessageSend:recipientId:plaintext:transaction: sets
    // isFriendRequest to true if the message in question is a friend request or a device linking request, but NOT if
    // it's a session request.

    // TODO: Does the above make sense?

    public static func shouldUseFallbackEncryption(_ message: TSOutgoingMessage) -> Bool {
        return !isSessionRequired(for: message)
    }

    @objc(isSessionRequiredForMessage:)
    public static func isSessionRequired(for message: TSOutgoingMessage) -> Bool {
        if message is FriendRequestMessage { return false }
        else if message is LKSessionRequestMessage { return false }
        else if let message = message as? DeviceLinkMessage, message.kind == .request { return false }
        return true
    }
}