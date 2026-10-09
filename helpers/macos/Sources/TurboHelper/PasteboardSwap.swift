import AppKit
import TurboCore
import Foundation

/// The pasteboard side of `paste`: save the user's pasteboard, offer the
/// content through a lazy data provider (so the helper sees when the app reads it), and
/// put the user's contents back afterwards unless someone else wrote the pasteboard in
/// between. The saved contents stay in memory only and are never logged.
final class PasteboardSwap: NSObject, NSPasteboardItemDataProvider {
    private let pasteboard = NSPasteboard.general
    private var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
    private var payload = PastePayload(plain: "", html: nil)
    private var rtf: Data?
    private let lock = NSLock()
    private var reads: [(type: String, at: Date)] = []
    private let firstRead = DispatchSemaphore(value: 0)
    private var signalled = false
    private(set) var ourChangeCount = -1
    /// When ⌘V was sent (reads before that were someone else pasting).
    var pasteSentAt: Date?

    /// Save the current contents and put `payload` up (main thread).
    func install(_ payload: PastePayload) {
        self.payload = payload
        if let html = payload.html { rtf = Self.rtf(fromHTML: html) }
        saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        var types: [NSPasteboard.PasteboardType] = [.string]
        if payload.html != nil { types.append(.html) }
        if rtf != nil { types.append(.rtf) }
        item.setDataProvider(self, forTypes: types)
        pasteboard.writeObjects([item])
        ourChangeCount = pasteboard.changeCount
    }

    /// Lazy data: called (main thread) when an app reads a flavor.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .string: item.setString(payload.plain, forType: .string)
        case .html: if let h = payload.html { item.setString(h, forType: .html) }
        case .rtf: if let r = rtf { item.setData(r, forType: .rtf) }
        default: break
        }
        lock.lock()
        reads.append((type.rawValue, Date()))
        let first = !signalled
        signalled = true
        lock.unlock()
        if first { firstRead.signal() }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    /// Wait (calling thread, not main) until the pasteboard was read after ⌘V was sent
    /// and no further flavor was requested for `quiet` s, at most `timeout`. Reads before
    /// ⌘V (a clipboard manager copying every change, or the user pasting) do not count.
    /// Returns the times of the reads after ⌘V.
    func waitForRead(timeout: TimeInterval, quiet: TimeInterval) -> [Date] {
        let sent = pasteSentAt ?? Date.distantPast
        let until = Date().addingTimeInterval(timeout)
        func readsAfter() -> [Date] {
            lock.lock()
            defer { lock.unlock() }
            return reads.map(\.at).filter { $0 >= sent }
        }
        while readsAfter().isEmpty {
            if Date() >= until { return [] }
            _ = firstRead.wait(timeout: .now() + 0.02)
        }
        var lastCount = readsAfter().count
        while true {
            usleep(useconds_t(quiet * 1_000_000))
            let n = readsAfter().count
            if n == lastCount { break }
            lastCount = n
        }
        return readsAfter()
    }

    /// Reads that happened before ⌘V was sent (someone else pasted meanwhile).
    var readsBeforePaste: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let sent = pasteSentAt else { return 0 }
        return reads.filter { $0.at < sent }.count
    }

    /// Put the user's previous contents back unless the pasteboard changed since the
    /// helper wrote it (main thread). Returns the decision.
    func restore() -> PasteRestore.Decision {
        let decision = PasteRestore.decide(ourChangeCount: ourChangeCount, currentChangeCount: pasteboard.changeCount)
        guard decision == .restore else { return decision }
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.compactMap { flavors in
            guard !flavors.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (t, d) in flavors { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        saved = []
        return decision
    }

    /// RTF for apps that take rich text but not HTML (main thread: the HTML importer
    /// requires it).
    static func rtf(fromHTML html: String) -> Data? {
        guard let data = html.data(using: .utf8),
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return nil }
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
