import Foundation
import ProtlyCore

/// F02c (owner decision 2026-11-22, speculative send): the call on the text the proxy's window shows, started at the
/// tap while the whole-field read walks the cursor. Nothing it returns is shown or used until the read is proven whole
/// and equal to `units`: then `relay` is the call's stream, its buffered updates first (partials are cumulative, so the
/// newest one and the end are all that is kept). Otherwise it is cancelled at once, which ends the download (tokens
/// saved). A long draft may therefore be billed twice; that is accepted.
@MainActor
final class Speculative {
    let mode: ActionMode
    /// The window's text, compared with the read by UTF-16 units.
    let units: [UInt16]
    let relay: AsyncStream<ActionUpdate>
    private let sink: AsyncStream<ActionUpdate>.Continuation
    private var consumer: Task<Void, Never>?
    /// ms from the start to the call's first update, -1 until then (CI timing, never text).
    private(set) var firstMS = -1

    init(mode: ActionMode, text: String) {
        self.mode = mode
        units = Array(text.utf16)
        let (relay, sink) = AsyncStream<ActionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(2))
        self.relay = relay
        self.sink = sink
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { [weak self] in
            // Ending this loop (a cancel) ends the upstream stream, whose termination stops its producer.
            for await update in ActionClient.run(mode, text: text) {
                if let self, self.firstMS < 0 { self.firstMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                sink.yield(update)
            }
            sink.finish()
        }
        consumer = task
        // The relay's reader stopped (Cancel or a hide during the adopted call): stop the call too.
        sink.onTermination = { _ in task.cancel() }
    }

    deinit {
        // Released without being adopted or cancelled (the controller went): never leave the download running.
        consumer?.cancel()
    }

    /// The read is exactly the window's text: the call is the result.
    func matches(_ text: String) -> Bool { Array(text.utf16) == units }

    /// Not adopted: the download stops now and nothing it returned is ever shown.
    func cancel() {
        consumer?.cancel()
        consumer = nil
        sink.finish()
    }
}
