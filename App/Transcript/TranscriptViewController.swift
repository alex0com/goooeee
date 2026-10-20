import AppKit
import GoooeeeCore
import GoooeeeTranscript
import Observation
import QuartzCore

/// The chat transcript: a view-based table with one row per transcript row.
///
/// Engine events only mark messages dirty; the display link calls `controller.flush()` once per
/// frame while generating, and `transcriptDidUpdate` applies the minimal table update. Heights are
/// cached per row ID, signature, UI state and width, so unchanged rows are never re-measured.
@MainActor
final class TranscriptViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, TranscriptSink {
    private(set) var controller: ChatController?
    weak var workspace: WorkspaceModel? {
        didSet { context.workspace = workspace }
    }
    let context: TranscriptContext

    private var rows: [TranscriptRow] = []
    private let scrollView = NSScrollView()
    private let tableView = TranscriptTableView()
    private let jumpButton = NSButton()
    private var displayLink: CADisplayLink?
    private var isProgrammaticScroll = false
    private var isLoadingOlder = false
    private var scrollToBottomOnNextReload = true
    private var appliedRevision = -1
    private var appliedDark: Bool?
    private var lastWidth: CGFloat = 0
    private var needsHeightRefreshAfterResize = false
    private var observationGeneration = 0

    init(workspace: WorkspaceModel) {
        context = TranscriptContext(store: AppModel.shared.settingsStore)
        super.init(nibName: nil, bundle: nil)
        self.workspace = workspace
        context.workspace = workspace
        context.viewController = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: View setup

    override func loadView() {
        let root = TranscriptRootView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.onAppearanceChange = { [weak self] in self?.applySettingsIfNeeded() }
        root.onLiveResizeEnd = { [weak self] in self?.liveResizeEnded() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.postsFrameChangedNotifications = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        root.addSubview(scrollView)

        jumpButton.bezelStyle = .circular
        jumpButton.controlSize = .large
        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Jump to latest")
        jumpButton.imagePosition = .imageOnly
        jumpButton.toolTip = "Jump to latest"
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatest)
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            jumpButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(tableFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(editLastMessage(_:)), name: .editLastMessage, object: nil)

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applySettingsIfNeeded()
        if let controller, controller.isLoaded {
            transcriptDidUpdate(.full)
        }
        observeState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySettingsIfNeeded()
        updateDisplayLink()
        if controller?.isPinnedToBottom != false { scrollToBottom() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        displayLink?.isPaused = true
    }

    // MARK: Binding

    /// Shows another conversation. The old controller stops receiving updates.
    func bind(_ controller: ChatController) {
        guard self.controller !== controller else { return }
        releaseSink()
        context.cancelEditingSilently()
        self.controller = controller
        context.controller = controller
        context.expandedCode = []
        rows = []
        scrollToBottomOnNextReload = true
        if isViewLoaded {
            tableView.reloadData()
            jumpButton.isHidden = true
            observeState()
        }
        controller.sink = self
        // Settings may have changed while this conversation was in the background.
        if controller.isLoaded, controller.transcript.options != controller.makeOptions() {
            controller.rebuildTranscript()
        }
        updateDisplayLink()
    }

    /// SwiftUI dismantles this view controller when the chat column's view changes (showing or hiding
    /// the terminal), often after the replacement has already bound the same controller. Detach
    /// completely, so this one neither unhooks the replacement nor reacts to its own teardown.
    func unbind() {
        releaseSink()
        controller = nil
        context.controller = nil
        displayLink?.invalidate()
        displayLink = nil
        observationGeneration += 1
    }

    /// Stops updates from the current controller, unless another transcript has taken it over.
    private func releaseSink() {
        if controller?.sink === self { controller?.sink = nil }
    }

    // MARK: Observation

    /// Follows the generating state (display link) and the settings revision.
    private func observeState() {
        observationGeneration += 1
        let generation = observationGeneration
        let controller = self.controller
        withObservationTracking {
            _ = controller?.isGenerating
            _ = AppModel.shared.settingsStore.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.updateDisplayLink()
                self.applySettingsIfNeeded()
                self.observeState()
            }
        }
    }

    /// Re-renders everything when the settings or the appearance changed.
    func applySettingsIfNeeded() {
        guard isViewLoaded else { return }
        let store = AppModel.shared.settingsStore
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard store.revision != appliedRevision || isDark != appliedDark else { return }
        let firstTime = appliedDark == nil
        appliedRevision = store.revision
        appliedDark = isDark
        context.apply(store: store, isDark: isDark)
        guard let controller else { return }
        if firstTime {
            if !rows.isEmpty { reloadAll() }
        } else {
            controller.rebuildTranscript()
        }
    }

    // MARK: Display link

    private func updateDisplayLink() {
        guard let controller, isViewLoaded else { return }
        let needed = controller.isGenerating || controller.needsFlush
        if needed {
            if displayLink == nil {
                let link = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let controller else {
            link.isPaused = true
            return
        }
        controller.flush()
        if !controller.isGenerating && !controller.needsFlush {
            link.isPaused = true
        }
    }

    // MARK: TranscriptSink

    func transcriptDidUpdate(_ update: TranscriptUpdate) {
        guard isViewLoaded, let controller else { return }
        if update.isFullReload {
            let anchor = (scrollToBottomOnNextReload || controller.isPinnedToBottom) ? nil : captureAnchor()
            rows = controller.transcript.rows
            context.pruneHeights(keeping: Set(rows.map(\.id)))
            tableView.reloadData()
            if let anchor, restore(anchor) {
                // Kept the reading position.
            } else {
                scrollToBottom()
            }
            scrollToBottomOnNextReload = false
            updateJumpButton()
            return
        }

        rows = controller.transcript.rows
        var insertedUserRow = false
        if !update.steps.isEmpty {
            tableView.beginUpdates()
            for step in update.steps {
                if !step.removed.isEmpty {
                    tableView.removeRows(at: step.removed, withAnimation: [])
                }
                if !step.inserted.isEmpty {
                    tableView.insertRows(at: step.inserted, withAnimation: [])
                }
            }
            tableView.endUpdates()
            if let last = update.steps.last?.inserted, last.contains(where: { index in
                guard index < rows.count, case .user = rows[index].kind else { return false }
                return true
            }) {
                insertedUserRow = true
            }
        }
        if !update.reloaded.isEmpty {
            refresh(update.reloaded)
        }
        followBottom(force: insertedUserRow)
    }

    private func reloadAll() {
        rows = controller?.transcript.rows ?? []
        tableView.reloadData()
        if controller?.isPinnedToBottom != false { scrollToBottom() }
    }

    // MARK: Row refresh

    /// Re-configures rows in place and updates the heights that changed.
    private func refresh(_ indexes: IndexSet) {
        var reload = IndexSet()
        var heightChanged = IndexSet()
        let width = layoutWidth
        for index in indexes where index < rows.count {
            let row = rows[index]
            let height = context.height(for: row, width: width)
            if abs(tableView.rect(ofRow: index).height - height) > 0.5 {
                heightChanged.insert(index)
            }
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptCellView {
                if cell.identifier == context.cellKind(for: row).identifier {
                    cell.configure(row, context: context)
                } else {
                    reload.insert(index)
                }
            }
        }
        if !reload.isEmpty {
            tableView.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0))
        }
        if !heightChanged.isEmpty {
            noteHeights(heightChanged)
        }
    }

    private func noteHeights(_ indexes: IndexSet) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        NSAnimationContext.endGrouping()
    }

    /// Rows matching `predicate` are re-measured and re-configured (UI state changed).
    func refreshRows(_ predicate: (TranscriptRow) -> Bool) {
        let indexes = IndexSet(rows.indices.filter { predicate(rows[$0]) })
        guard !indexes.isEmpty else { return }
        let wasPinned = controller?.isPinnedToBottom == true && distanceFromBottom < 4
        refresh(indexes)
        if wasPinned { scrollToBottom() }
    }

    /// Only heights (the editor grew while typing).
    func refreshHeights(_ predicate: (TranscriptRow) -> Bool) {
        let width = layoutWidth
        var changed = IndexSet()
        for index in rows.indices where predicate(rows[index]) {
            if abs(tableView.rect(ofRow: index).height - context.height(for: rows[index], width: width)) > 0.5 {
                changed.insert(index)
            }
        }
        if !changed.isEmpty { noteHeights(changed) }
    }

    /// Re-applies the row's content (highlighting finished).
    func reconfigureRow(id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }),
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptCellView,
            cell.identifier == context.cellKind(for: rows[index]).identifier
        else { return }
        cell.configure(rows[index], context: context)
    }

    /// After an in-place edit the row structs may change without a structural update.
    func syncRowsAfterEdit() {
        guard let controller else { return }
        let latest = controller.transcript.rows
        if latest.count == rows.count, zip(latest, rows).allSatisfy({ $0.id == $1.id }) {
            rows = latest
        } else {
            rows = latest
            tableView.reloadData()
        }
    }

    func scrollToEditor(messageID: UUID) {
        guard let index = rows.lastIndex(where: { $0.messageID == messageID && context.cellKind(for: $0) == .editor }) else { return }
        let rect = tableView.rect(ofRow: index)
        let visible = scrollView.contentView.bounds
        if rect.minY < visible.minY || rect.maxY > visible.maxY {
            scroll(toY: rect.minY - 40)
        }
    }

    // MARK: Table data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        return context.height(for: rows[row], width: layoutWidth)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        let kind = context.cellKind(for: item)
        let cell = (tableView.makeView(withIdentifier: kind.identifier, owner: nil) as? TranscriptCellView) ?? kind.makeView()
        cell.identifier = kind.identifier
        cell.configure(item, context: context)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("transcript.rowView")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptRowView { return reused }
        let rowView = TranscriptRowView()
        rowView.identifier = identifier
        return rowView
    }

    // MARK: Width changes

    private var layoutWidth: CGFloat {
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : scrollView.contentView.bounds.width
        return max(240, width.rounded(.down))
    }

    @objc private func tableFrameChanged(_ note: Notification) {
        let width = layoutWidth
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        guard !rows.isEmpty else { return }
        let wasPinned = controller?.isPinnedToBottom != false
        let anchor = wasPinned ? nil : captureAnchor()
        isProgrammaticScroll = true
        if view.inLiveResize {
            let visible = tableView.rows(in: tableView.visibleRect)
            if let range = Range<Int>(visible) {
                noteHeights(IndexSet(integersIn: range))
            }
            needsHeightRefreshAfterResize = true
        } else {
            noteHeights(IndexSet(integersIn: 0..<rows.count))
        }
        isProgrammaticScroll = false
        if wasPinned {
            scrollToBottom()
        } else if let anchor {
            _ = restore(anchor)
        }
    }

    private func liveResizeEnded() {
        guard needsHeightRefreshAfterResize, !rows.isEmpty else { return }
        needsHeightRefreshAfterResize = false
        let wasPinned = controller?.isPinnedToBottom != false
        let anchor = wasPinned ? nil : captureAnchor()
        isProgrammaticScroll = true
        noteHeights(IndexSet(integersIn: 0..<rows.count))
        isProgrammaticScroll = false
        if wasPinned {
            scrollToBottom()
        } else if let anchor {
            _ = restore(anchor)
        }
    }

    // MARK: Scrolling

    private var distanceFromBottom: CGFloat {
        let clip = scrollView.contentView.bounds
        return tableView.frame.height + scrollView.contentInsets.bottom - clip.maxY
    }

    private func followBottom(force: Bool) {
        guard let controller else { return }
        if force { controller.isPinnedToBottom = true }
        guard controller.isPinnedToBottom else {
            updateJumpButton()
            return
        }
        if force || !context.settings.disableAutoScroll || !controller.isGenerating {
            scrollToBottom()
        } else {
            updateJumpButton()
        }
    }

    func scrollToBottom() {
        guard isViewLoaded, !rows.isEmpty else { return }
        let bottom = tableView.rect(ofRow: rows.count - 1).maxY
        if tableView.frame.height < bottom - 0.5 {
            tableView.tile()
        }
        scroll(toY: .greatestFiniteMagnitude)
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let maxY = max(-insets.top, tableView.frame.height - clip.bounds.height + insets.bottom)
        let target = min(max(y, -insets.top), maxY)
        guard abs(clip.bounds.minY - target) > 0.25 else {
            updateJumpButton()
            return
        }
        isProgrammaticScroll = true
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
        isProgrammaticScroll = false
        updateJumpButton()
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        updateJumpButton()
        guard !isProgrammaticScroll, let controller else { return }
        let pinned = distanceFromBottom < 24
        if controller.isPinnedToBottom != pinned {
            controller.isPinnedToBottom = pinned
        }
        loadOlderIfNeeded()
    }

    private func updateJumpButton() {
        let hidden = controller?.isPinnedToBottom != false || distanceFromBottom < 120
        if jumpButton.isHidden != hidden { jumpButton.isHidden = hidden }
    }

    @objc private func jumpToLatest() {
        controller?.isPinnedToBottom = true
        scrollToBottom()
    }

    /// The first visible row and the rows above it, so the position survives when that row is replaced
    /// (branch switch, deletion).
    private struct Anchor {
        var rowIDs: [String]
        var offset: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        let visible = scrollView.contentView.bounds
        let index = tableView.row(at: NSPoint(x: 1, y: max(0, visible.minY + scrollView.contentInsets.top + 1)))
        guard index >= 0, index < rows.count else { return nil }
        let ids = rows[max(0, index - 20)...index].reversed().map(\.id)
        return Anchor(rowIDs: ids, offset: visible.minY - tableView.rect(ofRow: index).minY)
    }

    private func restore(_ anchor: Anchor) -> Bool {
        guard !rows.isEmpty else { return false }
        for (position, id) in anchor.rowIDs.enumerated() {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
            if tableView.frame.height < tableView.rect(ofRow: rows.count - 1).maxY - 0.5 {
                tableView.tile()
            }
            scroll(toY: tableView.rect(ofRow: index).minY + (position == 0 ? anchor.offset : 0))
            return true
        }
        return false
    }

    // MARK: Older messages

    private func loadOlderIfNeeded() {
        guard let controller, controller.transcript.hasOlderMessages, !isLoadingOlder else { return }
        let clip = scrollView.contentView.bounds
        guard clip.minY + scrollView.contentInsets.top < 600 else { return }
        isLoadingOlder = true
        Task { @MainActor [weak self] in
            self?.performLoadOlder()
        }
    }

    private func performLoadOlder() {
        defer { isLoadingOlder = false }
        guard let controller else { return }
        let anchor = captureAnchor()
        let update = controller.loadOlder()
        guard update.prependedCount > 0 else { return }
        rows = controller.transcript.rows
        tableView.beginUpdates()
        tableView.insertRows(at: IndexSet(integersIn: 0..<update.prependedCount), withAnimation: [])
        tableView.endUpdates()
        if let anchor {
            _ = restore(anchor)
        }
    }

    // MARK: Editing shortcut

    @objc private func editLastMessage(_ note: Notification) {
        guard let controller, (note.object as? UUID) == controller.id, !controller.isGenerating,
            let row = rows.last(where: { if case .user = $0.kind { return true } else { return false } })
        else { return }
        context.startEditing(row.messageID)
    }
}

// MARK: - Supporting views

/// Table view that doesn't draw selection or take focus.
final class TranscriptTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// Row view without selection or separators.
final class TranscriptRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// Root view: reports appearance changes and the end of live resizing.
final class TranscriptRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    var onLiveResizeEnd: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnd?()
    }
}
