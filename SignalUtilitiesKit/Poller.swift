import PromiseKit

@objc(LKPoller)
public final class Poller : NSObject {
    private let storage = OWSPrimaryStorage.shared()
    private var isPolling = false
    private var usedSnodes = Set<Snode>()
    private var pollCount = 0

    // MARK: Settings
    private static let pollInterval: TimeInterval = 1
    private static let retryInterval: TimeInterval = 0.25
    /// After polling a given snode this many times we always switch to a new one.
    ///
    /// The reason for doing this is that sometimes a snode will be giving us successful responses while
    /// it isn't actually getting messages from other snodes.
    private static let maxPollCount: UInt = 6

    // MARK: Error
    private enum Error : LocalizedError {
        case pollLimitReached

        var localizedDescription: String {
            switch self {
            case .pollLimitReached: return "Poll limit reached for current snode."
            }
        }
    }

    // MARK: Public API
    @objc public func startIfNeeded() {
        guard !isPolling else { return }
        print("[Loki] Started polling.")
        isPolling = true
        setUpPolling()
    }

    @objc public func stop() {
        print("[Loki] Stopped polling.")
        isPolling = false
        usedSnodes.removeAll()
    }

    // MARK: Private API
    private func setUpPolling() {
        guard isPolling else { return }
        SnodeAPI.getSwarm(for: getUserHexEncodedPublicKey(), isForcedReload: true).then2 { [weak self] _ -> Promise<Void> in
            guard let strongSelf = self else { return Promise { $0.fulfill(()) } }
            strongSelf.usedSnodes.removeAll()
            let (promise, seal) = Promise<Void>.pending()
            strongSelf.pollNextSnode(seal: seal)
            return promise
        }.ensure(on: DispatchQueue.main) { [weak self] in // Timers don't do well on background queues
            guard let strongSelf = self, strongSelf.isPolling else { return }
            Timer.scheduledTimer(withTimeInterval: Poller.retryInterval, repeats: false) { _ in
                guard let strongSelf = self else { return }
                strongSelf.setUpPolling()
            }
        }
    }

    private func pollNextSnode(seal: Resolver<Void>) {
        let userPublicKey = getUserHexEncodedPublicKey()
        let swarm = SnodeAPI.swarmCache[userPublicKey] ?? []
        let unusedSnodes = Set(swarm).subtracting(usedSnodes)
        if !unusedSnodes.isEmpty {
            // randomElement() uses the system's default random generator, which is cryptographically secure
            let nextSnode = unusedSnodes.randomElement()!
            usedSnodes.insert(nextSnode)
            poll(nextSnode, seal: seal).done2 {
                seal.fulfill(())
            }.catch2 { [weak self] error in
                if let error = error as? Error, error == .pollLimitReached {
                    self?.pollCount = 0
                } else {
                    print("[Loki] Polling \(nextSnode) failed; dropping it and switching to next snode.")
                    SnodeAPI.dropSnodeFromSwarmIfNeeded(nextSnode, publicKey: userPublicKey)
                }
                self?.pollNextSnode(seal: seal)
            }
        } else {
            seal.fulfill(())
        }
    }

    private func poll(_ snode: Snode, seal longTermSeal: Resolver<Void>) -> Promise<Void> {
        guard isPolling else { return Promise { $0.fulfill(()) } }
        let userPublicKey = getUserHexEncodedPublicKey()
        return SnodeAPI.getRawMessages(from: snode, associatedWith: userPublicKey).then(on: DispatchQueue.main) { [weak self] rawResponse -> Promise<Void> in
            guard let strongSelf = self, strongSelf.isPolling else { return Promise { $0.fulfill(()) } }
            let messages = SnodeAPI.parseRawMessagesResponse(rawResponse, from: snode, associatedWith: userPublicKey)
            if !messages.isEmpty {
                print("[Loki] Received \(messages.count) new message(s).")
            }
            messages.forEach { json in
                guard let envelope = SSKProtoEnvelope.from(json) else { return }
                do {
                    let data = try envelope.serializedData()
                    SSKEnvironment.shared.messageReceiver.handleReceivedEnvelopeData(data)
                } catch {
                    print("[Loki] Failed to deserialize envelope due to error: \(error).")
                }
            }
            strongSelf.pollCount += 1
            if strongSelf.pollCount == Poller.maxPollCount {
                throw Error.pollLimitReached
            } else {
                return withDelay(Poller.pollInterval, completionQueue: SnodeAPI.workQueue) {
                    guard let strongSelf = self, strongSelf.isPolling else { return Promise { $0.fulfill(()) } }
                    return strongSelf.poll(snode, seal: longTermSeal)
                }
            }
        }
    }
}
