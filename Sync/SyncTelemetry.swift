/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Account

// MARK: Stats/Telemetry structures
public protocol SyncStats {
    func hasData() -> Bool
}

public struct SyncUploadStats: SyncStats {
    var sent: Int = 0
    var sentFailed: Int = 0

    public func hasData() -> Bool {
        return sent > 0 || sentFailed > 0
    }
}

public struct SyncDownloadStats: SyncStats {
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

// TODO: Implement various bookmark validation issues we can run into
public struct ValidationStats {}

public struct SyncEngineStats {
    public let collection: String
    public var uploadStats: SyncUploadStats?
    public var downloadStats: SyncDownloadStats?
    public var took: UInt64 = 0
    public var failureReason: AnyObject?
    public var validationStats: ValidationStats?

    public init(collection: String) {
        self.collection = collection
    }
}

public class SyncStatsReport {
    private var when: Timestamp
    private var took: UInt64 = 0
    private var uid: String
    private var deviceID: String?
    private var didLogin: Bool
    private var why: String
    private var engines = [String: SyncEngineStats]()

    public init(when: Timestamp, account: FirefoxAccount, didLogin: Bool = false, why: String) {
        self.when = when
        self.uid = account.uid
        self.didLogin = didLogin
        self.why = why
        self.deviceID = account.deviceRegistration?.id
    }

    public func addStats(stats: SyncEngineStats, forEngine engine: String) {
        engines[engine] = stats
    }

    public func finishReport() {
        took = NSDate.now() - when
    }
}

public class EngineStatsRecorder {
    public var engineStats: SyncEngineStats

    private var startTime: Timestamp?

    public init(collection: String) {
        self.engineStats = SyncEngineStats(collection: collection)
    }

    public func start() {
        startTime = NSDate.now()
    }

    public func end() {
        guard let startTime = startTime else {
            assertionFailure("EngineStatsRecorder called end without first calling start!")
            return
        }
        engineStats.took = NSDate.now() - startTime
    }

    public func recordUploadStats(stats: SyncUploadStats) {
        engineStats.uploadStats = stats.hasData() ? stats : nil
    }

    public func recordDownloadStats(stats: SyncDownloadStats) {
        engineStats.downloadStats = stats.hasData() ? stats : nil
    }
}
