import Foundation

/// Runs async work one item at a time, in the order it was enqueued.
///
/// A bare `Task` per event gives no ordering once the work suspends: two
/// tasks interleave at every `await`. That matters when one item is several
/// requests that only make sense together — a slash command is typed, then
/// submitted, and a second command typed in between lands in the same line.
/// Each item here starts only after the previous one has finished.
///
/// Nothing is coalesced or dropped; a burst of events is a burst of items.
@MainActor
public final class SerialTaskQueue {

    /// The most recently enqueued item. Each new item awaits it, so the
    /// chain is only ever as long as the work still pending: a finished task
    /// has already released what it captured.
    private var tail: Task<Void, Never>?

    public init() {}

    /// Appends `work`. The returned task finishes when `work` does; callers
    /// may ignore it.
    @discardableResult
    public func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        return task
    }
}
