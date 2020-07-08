import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • For write transactions, consider making it the caller's responsibility to manage the database transaction (this helps avoid unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.
// • Document the expected cases in which a function will be used
// • Express those cases in tests.

@objc(LKMultiDeviceProtocol)
public final class MultiDeviceProtocol : NSObject {

    /// A mapping from hex encoded public key to date updated.
    ///
    /// - Note: Should only be accessed from `LokiAPI.workQueue` to avoid race conditions.
    public static var lastDeviceLinkUpdate: [String:Date] = [:]

    internal static var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }

    // MARK: - Settings
    public static let deviceLinkUpdateInterval: TimeInterval = 60
    
    // MARK: - Multi Device Destination
    public struct MultiDeviceDestination : Hashable {
        public let publicKey: String
        public let isMaster: Bool
    }

    // MARK: - General

    public static func sendSessionResetRequestToLinkedDevice(to hexEncodedPublicKey: String) {
        storage.dbReadWriteConnection.readWrite{ transaction in
            //Prevent the freeze issue
            SSKEnvironment.shared.profileManager.ensureProfileCachedForContact(withID: hexEncodedPublicKey, with: transaction)
        }
        storage.dbReadWriteConnection.readWrite{ transaction in
            let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
            let masterThread = TSContactThread.getOrCreateThread(withContactId: masterHexEncodedPublicKey, transaction: transaction)
            masterThread.sessionResetStatus = .initiated
            masterThread.save(with: transaction)
            let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
            let sessionRestorationRequestMessage = SessionRestoreMessage(thread: thread)
            sessionRestorationRequestMessage.save(with: transaction)
            let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
            messageSenderJobQueue.add(message: sessionRestorationRequestMessage, transaction: transaction)
        }
    }

    @objc(isUnlinkDeviceMessage:)
    public static func isUnlinkDeviceMessage(_ dataMessage: SSKProtoDataMessage) -> Bool {
        let unlinkDeviceFlag = SSKProtoDataMessage.SSKProtoDataMessageFlags.unlinkDevice
        return dataMessage.flags & UInt32(unlinkDeviceFlag.rawValue) != 0
    }

    public static func getUserLinkedDevices() -> Set<String> {
        var result: Set<String> = []
        storage.dbReadConnection.read { transaction in
            result = LokiDatabaseUtilities.getLinkedDeviceHexEncodedPublicKeys(for: getUserHexEncodedPublicKey(), in: transaction)
        }
        return result
    }

    @objc public static func isSlaveThread(_ thread: TSThread) -> Bool {
        guard let thread = thread as? TSContactThread else { return false }
        var isSlaveThread = false
        storage.dbReadConnection.read { transaction in
            isSlaveThread = storage.getMasterHexEncodedPublicKey(for: thread.contactIdentifier(), in: transaction) != nil
        }
        return isSlaveThread
    }

    // MARK: - Sending (Part 1)

    @objc(isMultiDeviceRequiredForMessage:toPublicKey:)
    public static func isMultiDeviceRequired(for message: TSOutgoingMessage, to publicKey: String) -> Bool {
        return !(message is DeviceLinkMessage) && !(message is UnlinkDeviceMessage) && (message.thread as? TSGroupThread)?.groupModel.groupType != .openGroup
            && !Storage.getUserClosedGroupPublicKeys().contains(publicKey)
    }

    private static func copy(_ messageSend: OWSMessageSend, for destination: MultiDeviceDestination, with seal: Resolver<Void>) -> OWSMessageSend {
        var recipient: SignalRecipient!
        storage.dbReadConnection.read { transaction in
            recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: destination.publicKey, transaction: transaction)
        }
        // TODO: Why is it okay that the thread, sender certificate, etc. don't get changed?
        return OWSMessageSend(message: messageSend.message, thread: messageSend.thread, recipient: recipient,
            senderCertificate: messageSend.senderCertificate, udAccess: messageSend.udAccess, localNumber: messageSend.localNumber, success: {
            seal.fulfill(())
        }, failure: { error in
            seal.reject(error)
        })
    }

    private static func sendMessage(_ messageSend: OWSMessageSend, to destination: MultiDeviceDestination, in transaction: YapDatabaseReadTransaction) -> Promise<Void> {
        let (threadPromise, threadPromiseSeal) = Promise<TSThread>.pending()
        if messageSend.message.thread.isGroupThread() {
            threadPromiseSeal.fulfill(messageSend.message.thread)
        } else if let thread = TSContactThread.getWithContactId(destination.publicKey, transaction: transaction) {
            threadPromiseSeal.fulfill(thread)
        } else {
            Storage.write { transaction in
                let thread = TSContactThread.getOrCreateThread(withContactId: destination.publicKey, transaction: transaction)
                threadPromiseSeal.fulfill(thread)
            }
        }
        return threadPromise.then2 { thread -> Promise<Void> in
            let message = messageSend.message
            let messageSender = SSKEnvironment.shared.messageSender
            let (promise, seal) = Promise<Void>.pending()
            let shouldSendAutoGeneratedFR = !thread.isContactFriend && !(message is FriendRequestMessage)
                && !SessionMetaProtocol.isThreadNoteToSelf(thread) && !thread.isGroupThread() // Group threads work through session requests
                && message.shouldBeSaved() // shouldBeSaved indicates it isn't a transient message
            if !shouldSendAutoGeneratedFR {
                let messageSendCopy = copy(messageSend, for: destination, with: seal)
                OWSDispatch.sendingQueue().async {
                    messageSender.sendMessage(messageSendCopy)
                }
            } else {
                Storage.write { transaction in
                    getAutoGeneratedMultiDeviceFRMessageSend(for: destination.publicKey, in: transaction, seal: seal)
                    .done(on: OWSDispatch.sendingQueue()) { autoGeneratedFRMessageSend in
                        messageSender.sendMessage(autoGeneratedFRMessageSend)
                    }
                }
            }
            return promise
        }
    }

    /// See [Multi Device Message Sending](https://github.com/loki-project/session-protocol-docs/wiki/Multi-Device-Message-Sending) for more information.
    @objc(sendMessageToDestinationAndLinkedDevices:transaction:)
    public static func sendMessageToDestinationAndLinkedDevices(_ messageSend: OWSMessageSend, in transaction: YapDatabaseReadTransaction) {
//        if !messageSend.isUDSend && messageSend.recipient.recipientId() != getUserHexEncodedPublicKey() {
//            #if DEBUG
//            preconditionFailure()
//            #endif
//        }
        let message = messageSend.message
        let messageSender = SSKEnvironment.shared.messageSender
        if !isMultiDeviceRequired(for: message, to: messageSend.recipient.recipientId()) {
            print("[Loki] sendMessageToDestinationAndLinkedDevices(_:in:) invoked for a message that doesn't require multi device routing.")
            OWSDispatch.sendingQueue().async {
                messageSender.sendMessage(messageSend)
            }
            return
        }
        print("[Loki] Sending \(type(of: message)) message using multi device routing.")
        let publicKey = messageSend.recipient.recipientId()
        getMultiDeviceDestinations(for: publicKey, in: transaction).done2 { destinations in
            var promises: [Promise<Void>] = []
            let masterDestination = destinations.first { $0.isMaster }
            if let masterDestination = masterDestination {
                storage.dbReadConnection.read { transaction in
                    promises.append(sendMessage(messageSend, to: masterDestination, in: transaction))
                }
            }
            let slaveDestinations = destinations.filter { !$0.isMaster }
            slaveDestinations.forEach { slaveDestination in
                storage.dbReadConnection.read { transaction in
                    promises.append(sendMessage(messageSend, to: slaveDestination, in: transaction))
                }
            }
            when(resolved: promises).done(on: OWSDispatch.sendingQueue()) { results in
                let errors = results.compactMap { result -> Error? in
                    if case Result.rejected(let error) = result {
                        return error
                    } else {
                        return nil
                    }
                }
                if errors.isEmpty {
                    messageSend.success()
                } else {
                    messageSend.failure(errors.first!)
                }
            }
        }.catch2 { error in
            // Proceed even if updating the recipient's device links failed, so that message sending
            // is independent of whether the file server is online
            OWSDispatch.sendingQueue().async {
                messageSender.sendMessage(messageSend)
            }
        }
    }

    /// See [Auto-Generated Friend Requests](https://github.com/loki-project/session-protocol-docs/wiki/Auto-Generated-Friend-Requests) for more information.
    public static func getAutoGeneratedMultiDeviceFRMessage(for publicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> FriendRequestMessage {
        let thread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        return FriendRequestMessage(timestamp: NSDate.ows_millisecondTimeStamp(), thread: thread, body: "Please accept to enable messages to be synced across devices")
    }

    /// See [Auto-Generated Friend Requests](https://github.com/loki-project/session-protocol-docs/wiki/Auto-Generated-Friend-Requests) for more information.
    public static func getAutoGeneratedMultiDeviceFRMessageSend(for publicKey: String, in transaction: YapDatabaseReadWriteTransaction, seal externalSeal: Resolver<Void>? = nil) -> Promise<OWSMessageSend> {
        // We don't update the friend request status; that's done in OWSMessageSender.sendMessage(_:)
        let thread = TSContactThread.getOrCreateThread(withContactId: publicKey, transaction: transaction)
        let message = getAutoGeneratedMultiDeviceFRMessage(for: publicKey, in: transaction)
        let recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: publicKey, transaction: transaction)
        let udManager = SSKEnvironment.shared.udManager
        let senderCertificate = udManager.getSenderCertificate()
        SSKEnvironment.shared.profileManager.ensureProfileCachedForContact(withID: publicKey, with: transaction) // Prevent the line below from starting a write transaction
        let (promise, seal) = Promise<OWSMessageSend>.pending()
        SnodeAPI.workQueue.async {
            var recipientUDAccess: OWSUDAccess?
            if let senderCertificate = senderCertificate {
                recipientUDAccess = udManager.udAccess(forRecipientId: publicKey, requireSyncAccess: true)
            }
            let messageSend = OWSMessageSend(message: message, thread: thread, recipient: recipient, senderCertificate: senderCertificate,
                udAccess: recipientUDAccess, localNumber: getUserHexEncodedPublicKey(), success: {
                    externalSeal?.fulfill(())
            }, failure: { error in
                externalSeal?.reject(error)
            })
            seal.fulfill(messageSend)
        }
        return promise
    }

    @objc(updateDeviceLinksIfNeededForPublicKey:transaction:)
    public static func updateDeviceLinksIfNeeded(for publicKey: String, in transaction: YapDatabaseReadTransaction) -> AnyPromise {
        return AnyPromise.from(getMultiDeviceDestinations(for: publicKey, in: transaction))
    }

    // MARK: - Receiving

    @objc(handleDeviceLinkMessageIfNeeded:wrappedIn:transaction:)
    public static func handleDeviceLinkMessageIfNeeded(_ protoContent: SSKProtoContent, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        let publicKey = envelope.source! // Set during UD decryption
        guard let deviceLinkMessage = protoContent.lokiDeviceLinkMessage, let master = deviceLinkMessage.masterPublicKey,
            let slave = deviceLinkMessage.slavePublicKey, let slaveSignature = deviceLinkMessage.slaveSignature else {
            return print("[Loki] Received an invalid device link message.")
        }
        let deviceLinkingSession = DeviceLinkingSession.current
        if let masterSignature = deviceLinkMessage.masterSignature { // Authorization
            print("[Loki] Received a device link authorization from: \(publicKey).") // Intentionally not `master`
            if let deviceLinkingSession = deviceLinkingSession {
                deviceLinkingSession.processLinkingAuthorization(from: master, for: slave, masterSignature: masterSignature, slaveSignature: slaveSignature)
            } else {
                print("[Loki] Received a device link authorization without a session; ignoring.")
            }
            // Set any profile info (the device link authorization also includes the master device's profile info)
            if let dataMessage = protoContent.dataMessage {
                SessionMetaProtocol.updateDisplayNameIfNeeded(for: master, using: dataMessage, in: transaction)
                SessionMetaProtocol.updateProfileKeyIfNeeded(for: master, using: dataMessage)
            }
        } else { // Request
            print("[Loki] Received a device link request from: \(publicKey).") // Intentionally not `slave`
            if let deviceLinkingSession = deviceLinkingSession {
                deviceLinkingSession.processLinkingRequest(from: slave, to: master, with: slaveSignature)
            } else {
                NotificationCenter.default.post(name: .unexpectedDeviceLinkRequestReceived, object: nil)
            }
        }
    }

    @objc(handleUnlinkDeviceMessage:wrappedIn:transaction:)
    public static func handleUnlinkDeviceMessage(_ dataMessage: SSKProtoDataMessage, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        let publicKey = envelope.source! // Set during UD decryption
        // Check that the request was sent by our master device
        let userPublicKey = getUserHexEncodedPublicKey()
        guard let userMasterPublicKey = storage.getMasterHexEncodedPublicKey(for: userPublicKey, in: transaction) else { return }
        let wasSentByMasterDevice = (userMasterPublicKey == publicKey)
        guard wasSentByMasterDevice else { return }
        // Ignore the request if we don't know about the device link in question
        let masterDeviceLinks = storage.getDeviceLinks(for: userMasterPublicKey, in: transaction)
        if !masterDeviceLinks.contains(where: {
            $0.master.hexEncodedPublicKey == userMasterPublicKey && $0.slave.hexEncodedPublicKey == userPublicKey
        }) {
            return
        }
        FileServerAPI.getDeviceLinks(associatedWith: userPublicKey).done2 { slaveDeviceLinks in
            // Check that the device link IS present on the file server.
            // Note that the device link as seen from the master device's perspective has been deleted at this point, but the
            // device link as seen from the slave perspective hasn't.
            if slaveDeviceLinks.contains(where: {
                $0.master.hexEncodedPublicKey == userMasterPublicKey && $0.slave.hexEncodedPublicKey == userPublicKey
            }) {
                for deviceLink in slaveDeviceLinks { // In theory there should only be one
                    FileServerAPI.removeDeviceLink(deviceLink) // Attempt to clean up on the file server
                }
                UserDefaults.standard[.wasUnlinked] = true
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .dataNukeRequested, object: nil)
                }
            }
        }
    }
}

// MARK: - Sending (Part 2)

// Here (in a non-@objc extension) because it doesn't interoperate well with Obj-C
public extension MultiDeviceProtocol {

    fileprivate static func getMultiDeviceDestinations(for publicKey: String, in transaction: YapDatabaseReadTransaction) -> Promise<Set<MultiDeviceDestination>> {
        let (promise, seal) = Promise<Set<MultiDeviceDestination>>.pending()
        func getDestinations(in transaction: YapDatabaseReadTransaction? = nil) {
            storage.dbReadConnection.read { transaction in
                var destinations: Set<MultiDeviceDestination> = []
                let masterPublicKey = storage.getMasterHexEncodedPublicKey(for: publicKey, in: transaction) ?? publicKey
                let masterDestination = MultiDeviceDestination(publicKey: masterPublicKey, isMaster: true)
                destinations.insert(masterDestination)
                let deviceLinks = storage.getDeviceLinks(for: masterPublicKey, in: transaction)
                let slaveDestinations = deviceLinks.map { MultiDeviceDestination(publicKey: $0.slave.hexEncodedPublicKey, isMaster: false) }
                destinations.formUnion(slaveDestinations)
                seal.fulfill(destinations)
            }
        }
        let timeSinceLastUpdate: TimeInterval
        if let lastDeviceLinkUpdate = lastDeviceLinkUpdate[publicKey] {
            timeSinceLastUpdate = Date().timeIntervalSince(lastDeviceLinkUpdate)
        } else {
            timeSinceLastUpdate = .infinity
        }
        if timeSinceLastUpdate > deviceLinkUpdateInterval {
            let masterPublicKey = storage.getMasterHexEncodedPublicKey(for: publicKey, in: transaction) ?? publicKey
            FileServerAPI.getDeviceLinks(associatedWith: masterPublicKey).done2 { _ in
                getDestinations()
                lastDeviceLinkUpdate[publicKey] = Date()
            }.catch2 { error in
                if (error as? DotNetAPI.DotNetAPIError) == DotNetAPI.DotNetAPIError.parsingFailed {
                    // Don't immediately re-fetch in case of failure due to a parsing error
                    lastDeviceLinkUpdate[publicKey] = Date()
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
}
