/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Account

public protocol Stats {
    func hasData() -> Bool
}

public struct SyncUploadStats: Stats {
    var sent: Int = 0
    var sentFailed: Int = 0

    public func hasData() -> Bool {
        return sent > 0 || sentFailed > 0
    }
}

public struct SyncDownloadStats: Stats {
    var applied: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var newFailed: Int = 0
    var reconciled: Int = 0

    public func hasData() -> Bool {
        return applied > 0 ||
               succeeded > 0 ||
               failed > 0 ||
               newFailed > 0 ||
               reconciled > 0
    }
}

public func +=(statsA: SyncDownloadStats, statsB: SyncDownloadStats) -> SyncDownloadStats {
    return SyncDownloadStats(applied: statsA.applied + statsB.applied,
                             succeeded: statsA.succeeded + statsB.succeeded,
                             failed: statsA.failed + statsB.failed,
                             newFailed: statsA.newFailed + statsB.newFailed,
                             reconciled: statsA.reconciled + statsB.reconciled)
}

public func +=(statsA: SyncUploadStats, statsB: SyncUploadStats) -> SyncUploadStats {
    return SyncUploadStats(sent: statsA.sent + statsB.sent, sentFailed: statsA.sentFailed + statsB.sentFailed)
}

// TODO(sleroux): Implement various bookmark validation issues we can run into
public struct ValidationStats: Stats {
    public func hasData() -> Bool {
        return false
    }
}

public class StatsSession {
    private var took: UInt64 = 0
    private var startTime: Timestamp?

    public func start() {
        startTime = NSDate.now()
    }

    public func end() -> Self {
        guard let startTime = startTime else {
            assertionFailure("SyncOperationStats called end without first calling start!")
            return self
        }

        took = NSDate.now() - startTime
        return self
    }
}

// Stats about a single engine's sync
public class SyncEngineStatsSession: StatsSession {
    public let collection: String
    public var uploadStats: SyncUploadStats
    public var downloadStats: SyncDownloadStats
    public var failureReason: AnyObject?
    public var validationStats: ValidationStats?

    public init(collection: String) {
        self.collection = collection
        self.uploadStats = SyncUploadStats()
        self.downloadStats = SyncDownloadStats()
    }
}

// Stats and metadata for a sync operation
public class SyncOperationStatsSession: StatsSession {
    public let uid: String
    public let deviceID: String?
    public let didLogin: Bool
    public let why: String
    public let when: Timestamp

    public init(uid: String, deviceID: String?, when: Timestamp, why: String, didLogin: Bool = false) {
        self.uid = uid
        self.deviceID = deviceID
        self.when = when
        self.why = why
        self.didLogin = didLogin
    }
}
