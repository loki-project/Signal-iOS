import SessionUtilitiesKit

@objc(SNJobQueue)
public final class JobQueue : NSObject, JobDelegate {

    @objc public static let shared = JobQueue()

    @objc public func add(_ job: Job, using transaction: Any) {
        Configuration.shared.storage.persist(job, using: transaction)
        job.delegate = self
        job.execute()
    }

    public func handleJobSucceeded(_ job: Job) {
        Configuration.shared.storage.withAsync({ transaction in
            Configuration.shared.storage.markJobAsSucceeded(job, using: transaction)
        }, completion: {
            // Do nothing
        })
    }

    public func handleJobFailed(_ job: Job, with error: Error) {
        job.failureCount += 1
        let storage = Configuration.shared.storage
        storage.withAsync({ transaction in
            storage.persist(job, using: transaction)
        }, completion: { // Intentionally capture self
            if job.failureCount == type(of: job).maxFailureCount {
                storage.withAsync({ transaction in
                    storage.markJobAsFailed(job, using: transaction)
                }, completion: {
                    // Do nothing
                })
            } else {
                let retryInterval = self.getRetryInterval(for: job)
                Timer.weakScheduledTimer(withTimeInterval: retryInterval, target: self, selector: #selector(self.retry(_:)), userInfo: job, repeats: false)
            }
        })
    }

    private func getRetryInterval(for job: Job) -> TimeInterval {
        // Arbitrary backoff factor...
        // try  1 delay:  0.00s
        // try  2 delay:  0.19s
        // ...
        // try  5 delay:  1.30s
        // ...
        // try 11 delay: 61.31s
        let backoffFactor = 1.9
        let maxBackoff: Double = 60 * 60 * 1000
        return 0.1 * min(maxBackoff, pow(backoffFactor, Double(job.failureCount)))
    }

    @objc private func retry(_ job: Any) {
        guard let job = job as? Job else { return }
        job.execute()
    }
}
