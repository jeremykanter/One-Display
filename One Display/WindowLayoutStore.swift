//
//  WindowLayoutStore.swift
//  One Display
//
//  Remembers window frames per display arrangement, on disk.
//
//  Titles are never stored — `WindowIdentity` holds a hash (see
//  `hashedTitle`), so this file contains no readable document names or browser
//  page titles. At the 1000-record cap it weighs roughly 90 KB.
//

import Foundation

@MainActor
final class WindowLayoutStore {

    /// Global cap across every arrangement, oldest record evicted first.
    private static let maxRecords = 1000
    /// Arrangements are cheap but unbounded (every resolution and rearrangement
    /// makes one), so cap them too.
    private static let maxConfigs = 32
    private static let formatVersion = 1
    private static let saveDebounce: TimeInterval = 5

    private struct LayoutStoreData: Codable {
        var version: Int
        var configs: [String: ConfigBucket]
    }

    private(set) var configs: [String: ConfigBucket] = [:]
    var onLog: ((String) -> Void)?

    private var pendingSave: DispatchWorkItem?
    private var isDirty = false

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("One Display", isDirectory: true)
            .appendingPathComponent("window-layouts.json")
    }()

    // MARK: Reading

    /// Whether we have ever recorded this arrangement. A brand new arrangement
    /// is captured as a baseline rather than restored, so the caller needs to
    /// tell the two apart.
    func hasBucket(for config: String) -> Bool {
        configs[config]?.windows.isEmpty == false
    }

    func records(for config: String) -> [WindowRecord] {
        configs[config]?.windows ?? []
    }

    /// The frame currently remembered for one window, so capture can report how
    /// a recorded frame is changing over time.
    func existingRecord(config: String, identity: WindowIdentity) -> WindowRecord? {
        configs[config]?.windows.first { $0.identity == identity }
    }

    // MARK: Writing

    /// Insert or update the remembered frame for one window.
    func record(config: String,
                identity: WindowIdentity,
                frame: CGRect,
                displayUUID: String,
                resistant: Bool? = nil,
                now: Date = Date()) {
        var bucket = configs[config] ?? ConfigBucket(lastSeen: now)
        bucket.lastSeen = now

        if let index = bucket.windows.firstIndex(where: { $0.identity == identity }) {
            bucket.windows[index].frame = frame
            bucket.windows[index].displayUUID = displayUUID
            bucket.windows[index].lastSeen = now
            if let resistant { bucket.windows[index].resistant = resistant }
        } else {
            bucket.windows.append(WindowRecord(identity: identity,
                                               frame: frame,
                                               displayUUID: displayUUID,
                                               lastSeen: now,
                                               resistant: resistant ?? false))
        }

        configs[config] = bucket
        isDirty = true
    }

    /// Note that an app refused the frame we asked for. The achieved frame is
    /// stored instead, so we stop re-fighting the same window on every
    /// reconfiguration.
    func markResistant(config: String, identity: WindowIdentity, achievedFrame: CGRect) {
        guard var bucket = configs[config],
              let index = bucket.windows.firstIndex(where: { $0.identity == identity })
        else { return }
        bucket.windows[index].frame = achievedFrame
        bucket.windows[index].resistant = true
        configs[config] = bucket
        isDirty = true
    }

    func touch(config: String, now: Date = Date()) {
        guard var bucket = configs[config] else { return }
        bucket.lastSeen = now
        configs[config] = bucket
        isDirty = true
    }

    // MARK: Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(LayoutStoreData.self, from: data)
            guard decoded.version == Self.formatVersion else {
                onLog?("Window layouts: unrecognized format version — starting fresh.")
                return
            }
            configs = decoded.configs
            let count = configs.values.reduce(0) { $0 + $1.windows.count }
            onLog?("Window layouts: loaded \(count) window(s) across \(configs.count) arrangement(s).")
        } catch {
            // A corrupt file must never stop the app from launching.
            onLog?("Window layouts: could not read store (\(error.localizedDescription)) — starting fresh.")
        }
    }

    /// Throttled write. The immediate `save()` on quit does not run on a
    /// force-quit or a crash, so this is what actually protects the data.
    ///
    /// Deliberately a throttle, not a debounce: capture calls this every two
    /// seconds, so a debounce would cancel and re-arm forever and the file would
    /// never be written at all. Leaving an already-scheduled save alone bounds
    /// the write latency to `saveDebounce` instead.
    func scheduleSave() {
        guard isDirty, pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty else { return }

        configs = evict(configs, maxRecords: Self.maxRecords, maxConfigs: Self.maxConfigs)

        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(LayoutStoreData(version: Self.formatVersion,
                                                                configs: configs))
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
        } catch {
            onLog?("Window layouts: could not save (\(error.localizedDescription)).")
        }
    }
}
