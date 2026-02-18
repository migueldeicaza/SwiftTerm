//
//  IOInstrumentation.swift
//
//  Lightweight signposts + stats for IO latency and throughput.
//

import Foundation
import os

enum IOInstrumentation {
    static let enabledKey = "SwiftTermIOInstrumentationEnabled"
    static let overlayKey = "SwiftTermIOOverlayEnabled"

    static let isEnabled: Bool = {
#if DEBUG
        if let value = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
            return value
        }
        return true
#else
        return UserDefaults.standard.bool(forKey: enabledKey)
#endif
    }()

    static let overlayEnabled: Bool = {
#if DEBUG
        if let value = UserDefaults.standard.object(forKey: overlayKey) as? Bool {
            return value
        }
        return true
#else
        return UserDefaults.standard.bool(forKey: overlayKey)
#endif
    }()

    static let log = OSLog(subsystem: "SwiftTerm", category: "IO")

    struct Stats {
        var backlogBytes: Int = 0
        var lastFeedBytes: Int = 0
        var lastFeedDurationNs: UInt64 = 0
        var lastReadBytes: Int = 0
        var lastReadToFeedNs: UInt64 = 0
        var lastFeedToDisplayNs: UInt64 = 0
        var lastInputToSendNs: UInt64 = 0
        var lastSendToWriteNs: UInt64 = 0
        var lastInputToDisplayNs: UInt64 = 0
        var lastWriteErrno: Int32 = 0
    }

    private static let statsQueue = DispatchQueue(label: "swiftterm.io.stats")
    private static var stats = Stats()

    private static var lastInputNanos: UInt64 = 0
    private static var lastSendNanos: UInt64 = 0
    private static var lastReadNanos: UInt64 = 0
    private static var lastFeedEndNanos: UInt64 = 0

    static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func signpostEvent(_ name: StaticString) {
        guard isEnabled else { return }
        if #available(macOS 10.14, iOS 12, *) {
            os_signpost(.event, log: log, name: name)
        }
    }

    static func signpostBegin(_ name: StaticString) -> OSSignpostID? {
        guard isEnabled else { return nil }
        if #available(macOS 10.14, iOS 12, *) {
            let id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: name, signpostID: id)
            return id
        }
        return nil
    }

    static func signpostEnd(_ name: StaticString, id: OSSignpostID?) {
        guard isEnabled else { return }
        guard let id else { return }
        if #available(macOS 10.14, iOS 12, *) {
            os_signpost(.end, log: log, name: name, signpostID: id)
        }
    }

    static func recordInputEvent() {
        guard isEnabled else { return }
        let now = nowNanos()
        lastInputNanos = now
        signpostEvent("input")
    }

    static func recordSend(bytes: Int) {
        guard isEnabled else { return }
        let now = nowNanos()
        lastSendNanos = now
        signpostEvent("send")
        statsQueue.async {
            if self.lastInputNanos > 0 {
                let delta = now &- self.lastInputNanos
                if delta < 1_000_000_000 {
                    self.stats.lastInputToSendNs = delta
                }
            }
            self.publishStats()
        }
    }

    static func recordWriteCompleted(durationNs: UInt64, errno: Int32) {
        guard isEnabled else { return }
        statsQueue.async {
            self.stats.lastSendToWriteNs = durationNs
            self.stats.lastWriteErrno = errno
            self.publishStats()
        }
    }

    static func recordRead(bytes: Int) {
        guard isEnabled else { return }
        let now = nowNanos()
        lastReadNanos = now
        signpostEvent("read")
        statsQueue.async {
            self.stats.lastReadBytes = bytes
            self.publishStats()
        }
    }

    static func recordFeed(bytes: Int, durationNs: UInt64, feedStartNs: UInt64, feedEndNs: UInt64) {
        guard isEnabled else { return }
        lastFeedEndNanos = feedEndNs
        let readToFeed = lastReadNanos > 0 ? feedStartNs &- lastReadNanos : 0
        signpostEvent("feed")
        statsQueue.async {
            self.stats.lastFeedBytes = bytes
            self.stats.lastFeedDurationNs = durationNs
            if readToFeed > 0 {
                self.stats.lastReadToFeedNs = readToFeed
            }
            self.publishStats()
        }
    }

    static func recordDisplay() {
        guard isEnabled else { return }
        let now = nowNanos()
        signpostEvent("display")
        statsQueue.async {
            if self.lastFeedEndNanos > 0 {
                self.stats.lastFeedToDisplayNs = now &- self.lastFeedEndNanos
            }
            if self.lastInputNanos > 0 {
                let delta = now &- self.lastInputNanos
                if delta < 2_000_000_000 {
                    self.stats.lastInputToDisplayNs = delta
                }
            }
            self.publishStats()
        }
    }

    static func updateBacklog(bytes: Int) {
        guard isEnabled else { return }
        statsQueue.async {
            self.stats.backlogBytes = bytes
            self.publishStats()
        }
    }

    private static func publishStats() {
        guard overlayEnabled else { return }
        let snapshot = stats
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .swiftTermIOStatsDidUpdate,
                object: nil,
                userInfo: snapshot.userInfo
            )
        }
    }
}

extension IOInstrumentation.Stats {
    var userInfo: [AnyHashable: Any] {
        [
            "backlogBytes": backlogBytes,
            "lastFeedBytes": lastFeedBytes,
            "lastFeedDurationNs": lastFeedDurationNs,
            "lastReadBytes": lastReadBytes,
            "lastReadToFeedNs": lastReadToFeedNs,
            "lastFeedToDisplayNs": lastFeedToDisplayNs,
            "lastInputToSendNs": lastInputToSendNs,
            "lastSendToWriteNs": lastSendToWriteNs,
            "lastInputToDisplayNs": lastInputToDisplayNs,
            "lastWriteErrno": lastWriteErrno
        ]
    }
}

extension Notification.Name {
    static let swiftTermIOStatsDidUpdate = Notification.Name("SwiftTermIOStatsDidUpdate")
}
