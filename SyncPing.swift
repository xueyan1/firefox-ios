/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

private let log = Logger.syncLogger

// See http://gecko.readthedocs.io/en/latest/toolkit/components/telemetry/telemetry/data/sync-ping.html
private let PingVersion = 4

class SyncPing: TelemetryPing {
    var payload: JSON

    init?(profile: Profile, when: Int, took: Int, didLogin: Bool? = nil) {
        guard let uid = profile.getAccount()?.uid else {
            log.info("No account available. Ignoring Sync Ping creation.")
            return nil
        }

        let syncPayload =
            Payload(when: when,
                    took: took,
                    uid: uid,
                    didLogin: didLogin,
                    devices: [],
                    deviceID: nil,
                    status: nil,
                    why: nil,
                    failureReason: nil,
                    engines: nil)

        self.payload = JSON(syncPayload.description)
    }
}

extension SyncPing {

    // Adds a sync to the ping for sending later
    func addSync(info: [String: AnyObject]) {

    }
}

// MARK: Data Definitions 
// https://dxr.mozilla.org/mozilla-central/source/services/sync/tests/unit/sync_ping_schema.json

private struct Payload: CustomStringConvertible {
    let when: Int
    let took: Int
    let uid: String

    var didLogin: Bool?
    var devices: [Device]?
    var deviceID: String?
    var status: Status?
    var why: WhyReason?
    var failureReason: SyncError?
    var engines: [Engine]?

    var description: String {
        let out: NSMutableDictionary = [
            "when": when,
            "took": took,
            "uid": uid
        ]
        out.optAdd(didLogin, key: "didLogin")
        out.optAdd(devices?.description, key: "devices")
        out.optAdd(deviceID, key: "deviceID")
        out.optAdd(status?.description, key: "status")
        out.optAdd(why?.rawValue, key: "why")
        out.optAdd(failureReason?.description, key: "failureReason")
        out.optAdd(engines?.description, key: "engines")

        return JSON.stringify(out, pretty: true)
    }
}

private struct Device: CustomStringConvertible {
    let os: String
    let id: String
    let version: String

    var description: String {
        return JSON.stringify([
            "os": os,
            "id": id,
            "version": version
        ], pretty: true)
    }
}

private struct Status: CustomStringConvertible {
    var sync: String?
    var service: String?

    var description: String {
        let out = NSMutableDictionary()
        out.optAdd(sync, key: "sync")
        out.optAdd(service, key: "service")
        return JSON.stringify(out, pretty: true)
    }
}

private struct Engine: CustomStringConvertible {
    let name: EngineName

    var failureReason: SyncError?
    var took: Int?
    var status: String?
    var incoming: Incoming?
    var outgoing: [OutgoingBatch]?
    var validation: Validation?
    var error: SyncError?

    var description: String {
        let out = NSMutableDictionary(dictionary:  ["name": name.rawValue])
        out.optAdd(failureReason?.description, key: "failureReason")
        out.optAdd(took, key: "took")
        out.optAdd(status, key: "status")
        out.optAdd(incoming?.description, key: "incoming")
        out.optAdd(outgoing?.description, key: "outgoing")
        out.optAdd(validation?.description, key: "validation")
        out.optAdd(error?.description, key: "error")

        return JSON.stringify(out, pretty: true)
    }
}

private struct OutgoingBatch: CustomStringConvertible {
    var sent: Int?
    var failed: Int?

    var description: String {
        let out = NSMutableDictionary()
        out.optAdd(sent, key: "sent")
        out.optAdd(failed, key: "failed")

        return JSON.stringify(out, pretty: true)
    }
}

private struct Incoming: CustomStringConvertible {
    var applied: Int?
    var failed: Int?
    var newFailed: Int?
    var reconciled: Int?

    var description: String {
        let out = NSMutableDictionary()
        out.optAdd(applied, key: "applied")
        out.optAdd(failed, key: "failed")
        out.optAdd(newFailed, key: "newFailed")
        out.optAdd(reconciled, key: "reconciled")

        return JSON.stringify(out, pretty: true)
    }
}

private struct Validation: CustomStringConvertible {
    let checked: Int
    let failureReason: SyncError

    var took: Int?
    var version: Int?
    var problems: [ValidationProblem]?

    var description: String {
        let out = NSMutableDictionary(dictionary: [
            "checked": checked,
            "failureReason": failureReason.description
        ])
        out.optAdd(took, key: "took")
        out.optAdd(version, key: "version")
        out.optAdd(problems?.description, key: "problems")
        
        return JSON.stringify(out, pretty: true)
    }
}

private struct ValidationProblem: CustomStringConvertible {
    let name: String
    let count: Int

    var description: String {
        return JSON.stringify(NSDictionary(dictionary: ["name": name, "count": count]), pretty: true)
    }
}

private enum WhyReason: String {
    case Shutdown = "shutdown"
    case Scheduled = "scheduled"
    case User = "user"
}

private enum EngineName: String {
    case Bookmarks = "bookmarks"
    case Clients = "clients"
    case History = "history"
    case Passwords = "passwords"
    case Tabs = "tabs"
}

private enum AuthErrorFrom: String {
    case TokenServer = "tokenserver"
    case FxAccounts = "fxaccounts"
    case HAWKClient = "hawkclient"
}

protocol SyncError: CustomStringConvertible {}

private struct HTTPError: SyncError {
    let name = "httperror"
    let code: Int

    var description: String {
        return JSON.stringify(NSDictionary(dictionary: ["name": name, "code": code]), pretty: true)
    }
}

private struct SyncNSError: SyncError {
    let name = "nserror"
    let code: Int

    var description: String {
        return JSON.stringify(NSDictionary(dictionary: ["name": name, "code": code]), pretty: true)
    }
}
