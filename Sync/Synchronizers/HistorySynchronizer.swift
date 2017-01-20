/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger
import Deferred

private let log = Logger.syncLogger
private let HistoryTTLInSeconds = 5184000                   // 60 days.
let HistoryStorageVersion = 1

func makeDeletedHistoryRecord(guid: GUID) -> Record<HistoryPayload> {
    // Local modified time is ignored in upload serialization.
    let modified: Timestamp = 0

    // Sortindex for history is frecency. Make deleted items more frecent than almost
    // anything.
    let sortindex = 5_000_000

    let ttl = HistoryTTLInSeconds

    let json: JSON = JSON([
        "id": guid,
        "deleted": true,
        ])
    let payload = HistoryPayload(json)
    return Record<HistoryPayload>(id: guid, payload: payload, modified: modified, sortindex: sortindex, ttl: ttl)
}

func makeHistoryRecord(place: Place, visits: [Visit]) -> Record<HistoryPayload> {
    let id = place.guid
    let modified: Timestamp = 0    // Ignored in upload serialization.
    let sortindex = 1              // TODO: frecency!
    let ttl = HistoryTTLInSeconds
    let json: JSON = JSON([
        "id": id,
        "visits": visits.map { $0.toJSON() },
        "histUri": place.url,
        "title": place.title,
        ])
    let payload = HistoryPayload(json)
    return Record<HistoryPayload>(id: id, payload: payload, modified: modified, sortindex: sortindex, ttl: ttl)
}

public class HistorySynchronizer: IndependentRecordSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, delegate: SyncDelegate, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, delegate: delegate, basePrefs: basePrefs, collection: "history")
    }

    override var storageVersion: Int {
        return HistoryStorageVersion
    }

    private let batchSize: Int = 1000  // A balance between number of requests and per-request size.

    private func mask(maxFailures: Int) -> Maybe<()> -> Success {
        var failures = 0
        return { result in
            if result.isSuccess {
                return Deferred(value: result)
            }

            failures += 1
            if failures > maxFailures {
                return Deferred(value: result)
            }

            log.debug("Masking failure \(failures).")
            return succeed()
        }
    }

    // TODO: this function should establish a transaction at suitable points.
    // TODO: a much more efficient way to do this is to:
    // 1. Start a transaction.
    // 2. Try to update each place. Note failures.
    // 3. bulkInsert all failed updates in one go.
    // 4. Store all remote visits for all places in one go, constructing a single sequence of visits.
    func applyIncomingToStorage(storage: SyncableHistory, records: [Record<HistoryPayload>]) -> Success {
        var stats = SyncDownloadStats()

        // Skip over at most this many failing records before aborting the sync.
        let maskSomeFailures = self.mask(3)

        // TODO: it'd be nice to put this in an extension on SyncableHistory. Waiting for Swift 2.0...
        func applyRecord(rec: Record<HistoryPayload>) -> Success {
            let guid = rec.id
            let payload = rec.payload
            let modified = rec.modified

            // We apply deletions immediately. Yes, this will throw away local visits
            // that haven't yet been synced. That's how Sync works, alas.
            if payload.deleted {
                stats.applied += 1
                return storage.deleteByGUID(guid, deletedAt: modified).bind({ result in
                    if result.isSuccess {
                        stats.succeeded += 1
                    } else {
                        stats.failed += 1
                    }
                    return Deferred(value: result)
                }).bind(maskSomeFailures)
            }

            // It's safe to apply other remote records, too -- even if we re-download, we know
            // from our local cached server timestamp on each record that we've already seen it.
            // We have to reconcile on-the-fly: we're about to overwrite the server record, which
            // is our shared parent.
            let place = rec.payload.asPlace()

            if isIgnoredURL(place.url) {
                log.debug("Ignoring incoming record \(guid) because its URL is one we wish to ignore.")
                return succeed()
            }

            let placeThenVisits = storage.insertOrUpdatePlace(place, modified: modified)
                              >>> { storage.storeRemoteVisits(payload.visits, forGUID: guid) }
            return placeThenVisits.map({ result in
                stats.applied += 1
                if result.isFailure {
                    let reason = result.failureValue?.description ?? "unknown reason"
                    log.error("Record application failed: \(reason)")
                    stats.failed += 1
                } else {
                    stats.succeeded += 1
                }
                return result
            }).bind(maskSomeFailures)
        }

        return self.applyIncomingRecords(records, apply: applyRecord)
            >>> effect({
                self.statsSession.downloadStats += stats
            })
    }

    private func uploadModifiedPlaces(places: [(Place, [Visit])], lastTimestamp: Timestamp, fromStorage storage: SyncableHistory, withServer storageClient: Sync15CollectionClient<HistoryPayload>, inout stats: SyncUploadStats) -> DeferredTimestamp {
        log.info("Preparing upload…")

        // Build sequences of 1000 history items, sequence by sequence
        // These will be uploaded in smaller batches by the upload batcher, but we chunk here
        // in order to bound peak memory usage when we call makeHistoryRecord below.
        let toUpload = chunk(places, by: 1000)
        let perChunk: (ArraySlice<(Place, [Visit])>, Timestamp) -> DeferredTimestamp = { (records, timestamp) in
            let recs = records.map(makeHistoryRecord)
            log.info("Uploading \(recs.count) history items…")
            stats.sent += recs.count
            return self.uploadRecords(recs, lastTimestamp: timestamp, storageClient: storageClient) { result, lastModified in
                stats.sentFailed += result.failed.count
                // We don't do anything with failed.
                return storage.markAsSynchronized(result.success, modified: lastModified ?? timestamp)
            }
        }

        let start = deferMaybe(lastTimestamp)
        return walk(toUpload, start: start, f: perChunk)
    }

    private func uploadDeletedPlaces(guids: [GUID], lastTimestamp: Timestamp, fromStorage storage: SyncableHistory, withServer storageClient: Sync15CollectionClient<HistoryPayload>, inout stats: SyncUploadStats) -> DeferredTimestamp {
        let records = guids.map(makeDeletedHistoryRecord)
        stats.sent += records.count
        
        // Deletions are smaller, so upload 100 at a time.
        return self.uploadRecords(records, lastTimestamp: lastTimestamp, storageClient: storageClient) { result, lastModified in
            stats.sentFailed += result.failed.count
            return storage.markAsDeleted(result.success) >>> always(lastModified ?? lastTimestamp)
        }
    }

    private func uploadOutgoingFromStorage(storage: SyncableHistory, lastTimestamp: Timestamp, withServer storageClient: Sync15CollectionClient<HistoryPayload>) -> Success {
        var stats = SyncUploadStats()

        var workWasDone = false
        let uploadDeleted: Timestamp -> DeferredTimestamp = { timestamp in
            storage.getDeletedHistoryToUpload()
            >>== { guids in
                if !guids.isEmpty {
                    workWasDone = true
                }
                log.info("Uploading \(guids.count) deleted places.")
                return self.uploadDeletedPlaces(guids, lastTimestamp: timestamp, fromStorage: storage, withServer: storageClient, stats: &stats)
            }
        }

        let uploadModified: Timestamp -> DeferredTimestamp = { timestamp in
            storage.getModifiedHistoryToUpload()
                >>== { places in
                    if !places.isEmpty {
                        workWasDone = true
                    }
                    log.info("Uploading \(places.count) modified places.")
                    return self.uploadModifiedPlaces(places, lastTimestamp: timestamp, fromStorage: storage, withServer: storageClient, stats: &stats)
            }
        }

        // The last clause will checkpoint the DB. But we just checkpointed the DB after downloading records!
        // Yes, that's true. Either there will be lots of work to do (e.g., having just marked
        // thousands of records as uploaded, or dropping lots of deleted rows), and so it's
        // worthwhile… or there won't be much work to do, and the checkpoint will be cheap.
        // If we did nothing -- uploaded no deletions, uploaded no modified records -- then we
        // don't checkpoint at all.
        return deferMaybe(lastTimestamp)
          >>== uploadDeleted
          >>== uploadModified
           >>> effect({ log.debug("Done syncing. Work was done? \(workWasDone)") })
           >>> { workWasDone ? storage.doneUpdatingMetadataAfterUpload() : succeed() }    // A closure so we eval workWasDone after it's set!
           >>> effect({ self.statsSession.uploadStats += stats })
           >>> effect({ log.debug("Done.") })
    }

    /**
     * If the green light turns red, we don't want to continue to upload -- doing
     * so would cause us to fast-forward our last sync timestamp and skip whatever
     * we hadn't yet downloaded.
     */
    private func go(info: InfoCollections, greenLight: () -> Bool, downloader: BatchingDownloader<HistoryPayload>, history: SyncableHistory) -> SyncResult {

        if !greenLight() {
            log.info("Green light turned red. Stopping history download.")
            return deferMaybe(.Partial)
        }

        func applyBatched() -> Success {
            return self.applyIncomingToStorage(history, records: downloader.retrieve())
               >>> effect(downloader.advance)
        }

        func onBatchResult(result: Maybe<DownloadEndState>) -> SyncResult {
            guard let end = result.successValue else {
                log.warning("Got failure: \(result.failureValue!)")
                return deferMaybe(completedWithStats)
            }

            switch end {
            case .Complete:
                log.info("Done with batched mirroring.")
                return applyBatched()
                   >>> history.doneApplyingRecordsAfterDownload
                   >>> { deferMaybe(self.completedWithStats) }
            case .Incomplete:
                log.debug("Running another batch.")
                // This recursion is fine because Deferred always pushes callbacks onto a queue.
                return applyBatched()
                   >>> { self.go(info, greenLight: greenLight, downloader: downloader, history: history) }
            case .Interrupted:
                log.info("Interrupted. Aborting batching this time.")
                return deferMaybe(.Partial)
            case .NoNewData:
                log.info("No new data. No need to continue batching.")
                downloader.advance()
                return deferMaybe(completedWithStats)
            }
        }

        return downloader.go(info, limit: self.batchSize)
                         .bind(onBatchResult)
    }

    public func synchronizeLocalHistory(history: SyncableHistory, withServer storageClient: Sync15StorageClient, info: InfoCollections, greenLight: () -> Bool) -> SyncResult {
        if let reason = self.reasonToNotSync(storageClient) {
            return deferMaybe(.NotStarted(reason))
        }
        
        let encoder = RecordEncoder<HistoryPayload>(decode: { HistoryPayload($0) }, encode: { $0 })

        guard let historyClient = self.collectionClient(encoder, storageClient: storageClient) else {
            log.error("Couldn't make history factory.")
            return deferMaybe(FatalError(message: "Couldn't make history factory."))
        }

        let downloader = BatchingDownloader(collectionClient: historyClient, basePrefs: self.prefs, collection: "history")

        // The original version of the history synchronizer tracked its
        // own last fetched time. We need to migrate this into the
        // batching downloader.
        let since: Timestamp = self.lastFetched
        if since > downloader.lastModified {
            log.debug("Advancing downloader lastModified to synchronizer lastFetched \(since).")
            downloader.lastModified = since
            self.lastFetched = 0
        }

        statsSession.start()
        return self.go(info, greenLight: greenLight, downloader: downloader, history: history)
            >>== { syncResult in
                switch syncResult {
                case .Completed:
                    // When we're done downloading, we can upload.
                    return self.uploadOutgoingFromStorage(history,
                                                          lastTimestamp: 0,
                                                          withServer: historyClient)
                       >>> { deferMaybe(self.completedWithStats) }

                // If we didn't finish downloading, do nothing further -- just pass
                // through the download result.
                case .NotStarted(_):
                    return deferMaybe(syncResult)

                case .Partial:
                    log.debug("Didn't finish downloading history; not uploading yet.")
                    return deferMaybe(syncResult)
                }
        }
    }
}
