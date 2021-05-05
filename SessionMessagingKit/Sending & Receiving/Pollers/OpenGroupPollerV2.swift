import PromiseKit

@objc(SNOpenGroupPollerV2)
public final class OpenGroupPollerV2 : NSObject {
    private let server: String
    private var timer: Timer? = nil
    private var hasStarted = false
    private var isPolling = false

    private var isMainAppAndActive: Bool {
        var isMainAppAndActive = false
        if let sharedUserDefaults = UserDefaults(suiteName: "group.com.loki-project.loki-messenger") {
            isMainAppAndActive = sharedUserDefaults.bool(forKey: "isMainAppActive")
        }
        return isMainAppAndActive
    }

    // MARK: Settings
    private let pollInterval: TimeInterval = 4

    // MARK: Lifecycle
    public init(for server: String) {
        self.server = server
        super.init()
    }

    @objc public func startIfNeeded() {
        guard !hasStarted else { return }
        guard isMainAppAndActive else { stop(); return }
        DispatchQueue.main.async { [weak self] in // Timers don't do well on background queues
            guard let strongSelf = self else { return }
            strongSelf.hasStarted = true
            strongSelf.timer = Timer.scheduledTimer(withTimeInterval: strongSelf.pollInterval, repeats: true) { _ in self?.poll() }
            strongSelf.poll()
        }
    }

    @objc public func stop() {
        timer?.invalidate()
        hasStarted = false
    }

    // MARK: Polling
    @discardableResult
    public func poll() -> Promise<Void> {
        guard isMainAppAndActive else { stop(); return Promise.value(()) }
        return poll(isBackgroundPoll: false)
    }

    @discardableResult
    public func poll(isBackgroundPoll: Bool) -> Promise<Void> {
        guard !self.isPolling else { return Promise.value(()) }
        self.isPolling = true
        let (promise, seal) = Promise<Void>.pending()
        promise.retainUntilComplete()
        OpenGroupAPIV2.compactPoll(server).done(on: DispatchQueue.global(qos: .default)) { [weak self] bodies in
            guard let self = self else { return }
            self.isPolling = false
            bodies.forEach { self.handleCompactPollBody($0, isBackgroundPoll: isBackgroundPoll) }
            seal.fulfill(())
        }.catch(on: DispatchQueue.global(qos: .userInitiated)) { error in
            SNLog("Open group polling failed due to error: \(error).")
            self.isPolling = false
            seal.fulfill(()) // The promise is just used to keep track of when we're done
        }
        return promise
    }

    private func handleCompactPollBody(_ body: OpenGroupAPIV2.CompactPollResponseBody, isBackgroundPoll: Bool) {
        let storage = SNMessagingKitConfiguration.shared.storage
        // - Messages
        // Sorting the messages by server ID before importing them fixes an issue where messages that quote older messages can't find those older messages
        let openGroupID = "\(server).\(body.room)"
        let messages = body.messages.sorted { $0.serverID! < $1.serverID! } // Safe because messages with a nil serverID are filtered out
        messages.forEach { message in
            guard let data = Data(base64Encoded: message.base64EncodedData) else {
                return SNLog("Ignoring open group message with invalid encoding.")
            }
            let envelope = SNProtoEnvelope.builder(type: .sessionMessage, timestamp: message.sentTimestamp)
            envelope.setContent(data)
            envelope.setSource(message.sender!) // Safe because messages with a nil sender are filtered out
            envelope.setServerTimestamp(message.sentTimestamp)
            let job = MessageReceiveJob(data: try! envelope.buildSerializedData(), openGroupMessageServerID: UInt64(message.serverID!), openGroupID: openGroupID, isBackgroundPoll: isBackgroundPoll)
            storage.write { transaction in
                SessionMessagingKit.JobQueue.shared.add(job, using: transaction)
            }
        }
        // - Deletions
        let deletedMessageServerIDs = Set(body.deletions.map { UInt64($0.deletedMessageID) })
        storage.write { transaction in
            let transaction = transaction as! YapDatabaseReadWriteTransaction
            guard let threadID = storage.v2GetThreadID(for: openGroupID),
                let thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction) else { return }
            var messagesToRemove: [TSMessage] = []
            thread.enumerateInteractions(with: transaction) { interaction, stop in
                guard let message = interaction as? TSMessage, deletedMessageServerIDs.contains(message.openGroupServerMessageID) else { return }
                messagesToRemove.append(message)
            }
            messagesToRemove.forEach { $0.remove(with: transaction) }
        }
        // - Moderators
        if var x = OpenGroupAPIV2.moderators[server] {
            x[body.room] = Set(body.moderators)
            OpenGroupAPIV2.moderators[server] = x
        } else {
            OpenGroupAPIV2.moderators[server] = [body.room:Set(body.moderators)]
        }
    }
}
