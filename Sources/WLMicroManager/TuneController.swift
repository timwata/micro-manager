import Foundation
import WLKit

/// The dial and joystick: effort and model for whichever agent has focus.
///
/// Claude Code takes orders directly — `/effort <level>` and `/model <name>`
/// are commands, so the dial climbs an effort ladder and the joystick cycles
/// a model list, both configurable. Codex has bindable effort commands but
/// only a picker for models, so its dial sends the chords bound in
/// `[tui.keymap]` and its joystick drives the `/model` picker: north opens
/// it, north/south move, east confirms, west cancels.
///
/// Either way the joystick is working a list you cannot see from the pad, so
/// every deflection also puts that list on screen — see `TunePanelController`.
@MainActor
final class TuneController {

    static let shared = TuneController()

    /// The chords `~/.codex/config.toml` binds to
    /// `chat.increase_reasoning_effort` / `chat.decrease_reasoning_effort`.
    static let codexEffortUpChord = "ctrl+alt+u"
    static let codexEffortDownChord = "ctrl+alt+d"

    var onError: ((String) -> Void)?
    /// The bridge owns the loaded config; this reads through to it.
    var bindings: () -> KeyBindings = { KeyBindings() }

    /// Where each Claude pane sits on the effort ladder and model list. Blind
    /// state: it starts at the defaults and follows our own commands, so a
    /// change made by hand inside the session drifts it until the next nudge.
    private var claudeEffortIndex: [String: Int] = [:]
    private var claudeModelIndex: [String: Int] = [:]

    /// The codex pane whose `/model` picker we opened, if any. Deflections
    /// steer the picker only while this is fresh; a stale entry means the
    /// picker was dealt with by hand.
    private var codexPickerPane: String?
    private var codexPickerOpened: Date?
    private static let pickerLifetime: TimeInterval = 30

    /// Dial and joystick share one queue. A slash command is two requests —
    /// the text, then enter — so two in flight could type
    /// `/effort high/effort xhigh` into one line and leave a stray enter. One
    /// queue for both keeps a dial turn and a deflection to the same pane in
    /// the order they were made. Detents are not coalesced: each is one step
    /// on the ladder, and the index bookkeeping counts on that.
    private let queue = SerialTaskQueue()

    /// Bumped by `resetForTargetChange()`. Each item takes it when it is
    /// enqueued, not when it starts: an item still waiting in the queue at a
    /// target change would otherwise start after the switch, read the new
    /// generation as its own and act on the new target's focused pane. An
    /// item checks it when it starts, once it has the focused pane, and again
    /// before any state it writes after a send, so work aimed at the old
    /// server neither reaches the new one nor writes state keyed by an old
    /// pane id.
    private var generation = 0

    /// Pane ids are only unique per Herdr server, so on a target change all
    /// per-pane state is dropped: otherwise a pane on the new server could
    /// pick up another pane's ladder position, or steer a picker that was
    /// opened somewhere else. The model list goes too; it describes a pane
    /// the pad no longer shows.
    func resetForTargetChange() {
        generation += 1
        claudeEffortIndex = [:]
        claudeModelIndex = [:]
        codexPickerPane = nil
        codexPickerOpened = nil
        TunePanelController.shared.hide()
    }

    // MARK: - Dial: effort

    func handleDial(_ step: Int) {
        let generation = generation
        queue.enqueue { [self] in await dial(step, generation: generation) }
    }

    private func dial(_ step: Int, generation: Int) async {
        guard generation == self.generation else { return }
        guard let (agent, pane) = await focusedPane(), generation == self.generation else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                let ladder = bindings().claudeEfforts
                let index = climb(claudeEffortIndex[pane] ?? ladder.count / 2,
                                  by: step, within: ladder.count)
                claudeEffortIndex[pane] = index
                try await send(command: "/effort \(ladder[index])", to: pane)
            } else if kind.contains("codex") {
                try await HerdrClient.sendKeys(
                    paneID: pane,
                    keys: [step > 0 ? Self.codexEffortUpChord : Self.codexEffortDownChord]
                )
            } else {
                onError?("No effort control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Clamped, not wrapping: turning past the top should pin at max, not
    /// jump to low — a dial has ends even when the hardware spins freely.
    private func climb(_ index: Int, by step: Int, within count: Int) -> Int {
        max(0, min(count - 1, index + step))
    }

    // MARK: - Joystick: model

    func handleJoystick(_ direction: Pad.JoystickDirection) {
        let generation = generation
        queue.enqueue { [self] in await joystick(direction, generation: generation) }
    }

    private func joystick(_ direction: Pad.JoystickDirection, generation: Int) async {
        guard generation == self.generation else { return }
        guard let (agent, pane) = await focusedPane(), generation == self.generation else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                try await claudeModel(direction, pane: pane, agent: agent.shortName)
            } else if kind.contains("codex") {
                try await codexModel(direction, pane: pane, agent: agent.shortName, generation: generation)
            } else {
                onError?("No model control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Models cycle with wraparound — unlike effort, a list of names has no
    /// natural top or bottom.
    private func claudeModel(
        _ direction: Pad.JoystickDirection,
        pane: String,
        agent: String
    ) async throws {
        let models = bindings().claudeModels
        let step: Int
        switch direction {
        case .north: step = -1
        case .south: step = 1
        case .east, .west: return
        }
        let index = ((claudeModelIndex[pane] ?? 0) + step + models.count) % models.count
        claudeModelIndex[pane] = index
        // Up before the command goes out: the panel is the answer to "what did
        // I just land on", and waiting for the TUI to echo would show it late.
        TunePanelController.shared.showModels(
            models,
            current: index,
            agent: agent,
            hint: "north and south cycle the list"
        )
        try await send(command: "/model \(models[index])", to: pane)
    }

    private func codexModel(
        _ direction: Pad.JoystickDirection,
        pane: String,
        agent: String,
        generation: Int
    ) async throws {
        let pickerOpen = codexPickerPane == pane
            && Date().timeIntervalSince(codexPickerOpened ?? .distantPast) < Self.pickerLifetime

        guard pickerOpen else {
            // Any vertical deflection opens the picker; the rest is steering.
            guard direction == .north || direction == .south else { return }
            try await send(command: "/model", to: pane)
            // The picker state is written after the send; a target change in
            // between already dropped it, and `pane` belongs to the old server.
            guard generation == self.generation else { return }
            codexPickerPane = pane
            codexPickerOpened = Date()
            showCodexModels(agent: agent)
            return
        }

        let key: String
        switch direction {
        case .north: key = "up"
        case .south: key = "down"
        case .east: key = "enter"
        case .west: key = "esc"
        }
        try await HerdrClient.sendKeys(paneID: pane, keys: [key])
        // Same as above: after a target change the panel stays hidden.
        guard generation == self.generation else { return }

        switch direction {
        case .north, .south:
            showCodexModels(agent: agent)
        case .east, .west:
            codexPickerPane = nil
            TunePanelController.shared.hide()
        }
        codexPickerOpened = Date()
    }

    /// Codex's picker is its own; we push arrow keys at it without being told
    /// where the cursor sits, so the panel is a numbered reading of the list
    /// and nothing is marked as current.
    private func showCodexModels(agent: String) {
        TunePanelController.shared.showModels(
            bindings().codexModels,
            current: nil,
            agent: agent,
            hint: "north and south move · east confirms · west cancels"
        )
    }

    // MARK: - Plumbing

    private func focusedPane() async -> (HerdrAgent, String)? {
        guard let agent = try? await HerdrClient.focusedAgent(), let pane = agent.paneID else {
            onError?("Nothing has focus in Herdr right now.")
            return nil
        }
        return (agent, pane)
    }

    /// Slash commands go in as text plus enter: typed, then submitted.
    private func send(command: String, to pane: String) async throws {
        try await HerdrClient.sendText(paneID: pane, text: command)
        try await HerdrClient.sendKeys(paneID: pane, keys: ["enter"])
    }
}
