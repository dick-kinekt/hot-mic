import AppKit
import Combine
import SwiftUI

struct RecordingBarView: View {
    @ObservedObject var model: TranscriptionCoordinator
    let openSetup: () -> Void
    let onSizeChange: (CGSize) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hasAppeared = false

    var body: some View {
        let isVisible = model.isPresented && (hasAppeared || reduceMotion)
        VStack(alignment: .leading, spacing: 12) {
            header

            RecordingTranscriptPreview(model: model)

            if model.isError {
                recoveryContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: RecordingBarMetrics.width, alignment: .leading)
        .frame(minHeight: RecordingBarMetrics.compactHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSizeChange)
        .background(
            colorScheme == .dark ? Color(red: 0.085, green: 0.085, blue: 0.095) : Color(red: 0.985, green: 0.985, blue: 0.99),
            in: RoundedRectangle(cornerRadius: RecordingBarMetrics.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RecordingBarMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: visualState)
        .opacity(isVisible ? 1 : 0)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: model.isPresented ? RecordingBarMetrics.showDuration : RecordingBarMetrics.hideDuration),
            value: isVisible
        )
        .onAppear { hasAppeared = true }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            MicrophoneIndicator(
                isCapturing: model.capturing,
                isError: model.isError,
                reduceMotion: reduceMotion
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                    .contentTransition(.opacity)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.notice)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowElapsedTime {
                Text(elapsedTime)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .accessibilityLabel("Elapsed recording time \(elapsedTime)")
            }

            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1, height: 26)

            primaryAction

            Button(action: model.copyResult) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(RecordingBarIconButtonStyle(tint: Color(nsColor: .systemBlue)))
            .disabled(model.active || model.transcript.isEmpty || model.isClosing)
            .help(model.copySucceeded ? "Copied to clipboard. Click to copy again." : "Copy text to clipboard")
            .accessibilityLabel("Copy text")
            .accessibilityValue(model.copySucceeded ? "Copied" : "Not copied")

            Button(action: model.reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 36)
            }
            .buttonStyle(RecordingBarIconButtonStyle(tint: Color(nsColor: .systemOrange)))
            .help("Discard this dictation and reset the timer")
            .accessibilityLabel("Reset dictation")

            Button(action: model.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(RecordingBarIconButtonStyle(hoverTint: Color(nsColor: .systemRed)))
            .disabled(model.isClosing)
            .help(model.isClosing ? "Closing after dictation is safely copied" : "Close dictation")
            .accessibilityLabel(model.isClosing ? "Closing dictation" : "Close dictation")
        }
    }

    private var primaryAction: some View {
        Button(action: model.toggleRecording) {
            HStack(spacing: 4) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(colorScheme == .dark ? .black : .white)
                } else {
                    Image(systemName: primaryActionSymbol)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                Text(primaryActionTitle)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            .frame(width: 84)
        }
        .buttonStyle(RecordingBarPrimaryButtonStyle())
        .disabled(primaryActionDisabled)
        .help(primaryActionHelp)
        .accessibilityLabel(primaryActionHelp)
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.notice)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(action: model.copyResult) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(RecordingBarSecondaryButtonStyle())
                .disabled(!hasRecoverableText)
                .help(hasRecoverableText ? "Copy recovered dictation" : "There is no recovered text to copy")

                Button(action: openSetup) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(RecordingBarSecondaryButtonStyle())
                .help("Open Hot Mic settings")

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
        }
    }

    private var visualState: RecordingBarVisualState {
        if model.isError { return .error }
        if model.isClosing { return .closing }
        switch model.state {
        case .idle:
            return .idle
        case .starting:
            return .starting
        case .recording:
            return .recording
        case .finalizing:
            return .finalizing
        case .paused:
            return .paused
        }
    }

    private var statusTitle: String {
        if model.isShowingCopyConfirmation { return "Copied" }
        switch visualState {
        case .error:
            return "Needs attention"
        case .closing:
            return "Finishing up"
        case .idle:
            return "Ready to dictate"
        case .starting:
            return model.capturing ? "Recording" : "Getting ready"
        case .recording:
            return "Recording"
        case .finalizing:
            return "Finishing up"
        case .paused:
            if isEmptySession { return "Ready to dictate" }
            return model.copySucceeded ? "Copied" : "Stopped"
        }
    }

    private var statusDetail: String {
        if model.isShowingCopyConfirmation { return "Closing…" }
        if model.isError { return "Review the message below" }
        if model.isClosing { return "Finishing and copying your text" }

        switch model.state {
        case .idle:
            return "Press the shortcut to begin"
        case .starting:
            return model.capturing ? "Microphone on · connecting" : "Preparing microphone"
        case .recording:
            return model.capturing ? "Microphone on" : "Microphone off"
        case .finalizing:
            return "Microphone off · finishing text"
        case .paused:
            if model.isCleaningText { return "Cleaning with OpenAI…" }
            if let notice = model.cleanupNotice { return notice }
            return isEmptySession ? "Ready to start" : "Ready to resume"
        }
    }

    private var primaryActionTitle: String {
        if model.isShowingCopyConfirmation { return "Copied" }
        switch model.state {
        case .starting, .recording:
            return "Pause & copy"
        case .idle, .paused:
            return isEmptySession ? "Start" : "Resume"
        case .finalizing:
            return "Finishing"
        }
    }

    private var primaryActionSymbol: String {
        if model.isShowingCopyConfirmation { return "checkmark" }
        switch model.state {
        case .starting, .recording:
            return "pause.fill"
        case .idle, .paused:
            return "play.fill"
        case .finalizing:
            return "ellipsis"
        }
    }

    private var primaryActionHelp: String {
        if model.isShowingCopyConfirmation { return "Copied; closing dictation" }
        switch model.state {
        case .starting, .recording:
            return "Pause recording and copy the finished dictation"
        case .idle, .paused:
            return isEmptySession ? "Start dictation" : "Resume this dictation"
        case .finalizing:
            return "Dictation is still finalizing"
        }
    }

    private var primaryActionDisabled: Bool {
        model.state == .finalizing || model.isClosing
    }


    private var showsProgress: Bool {
        !model.isShowingCopyConfirmation && (model.state == .finalizing || model.isClosing)
    }

    private var isEmptySession: Bool {
        model.transcript.isEmpty && model.recordingSeconds == 0
    }

    private var shouldShowElapsedTime: Bool {
        model.state != .idle || model.recordingSeconds > 0
    }

    private var elapsedTime: String {
        let totalSeconds = max(0, Int(model.recordingSeconds.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var hasRecoverableText: Bool {
        !model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct RecordingTranscriptPreview: View {
    @ObservedObject var model: TranscriptionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    @State private var latestRequest = 0

    var body: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(model.active ? "Live transcript" : "Transcript")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help("Live wording may change until transcription is finalized.")

                        Spacer(minLength: 0)

                        if isExpanded {
                            Button("Latest") {
                                latestRequest &+= 1
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help("Scroll to the latest words")
                        }

                        Button {
                            if model.canUndoCleanup { model.undoCleanup() }
                            else { model.cleanUpText() }
                        } label: {
                            HStack(spacing: 4) {
                                if model.isCleaningText {
                                    ProgressView().controlSize(.mini)
                                    Text("Cleaning with OpenAI…")
                                } else {
                                    Image(systemName: model.canUndoCleanup ? "arrow.uturn.backward" : "sparkles")
                                        .foregroundStyle(cleanupActionAvailable ? Color(nsColor: .systemPurple) : Color.secondary)
                                    Text(model.canUndoCleanup ? "Undo cleanup" : "Clean up text")
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(cleanupActionAvailable ? Color.primary : Color.secondary)
                        .disabled(!cleanupActionAvailable)
                        .help(cleanupHelp)

                        Button {
                            isExpanded.toggle()
                        } label: {
                            Label(isExpanded ? "Collapse" : "Expand",
                                  systemImage: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .medium))
                                .frame(minHeight: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isExpanded ? "Collapse transcript preview" : "Expand transcript preview")
                        .help(isExpanded ? "Show the latest two lines" : "Review the full dictation")
                    }

                    if isExpanded {
                        FollowingTranscriptView(
                            text: model.previewTranscript.isEmpty ? emptyText : model.previewTranscript,
                            isPlaceholder: model.previewTranscript.isEmpty,
                            latestRequest: latestRequest
                        )
                        .frame(height: 180)
                    } else {
                        // Bottom alignment follows revisions without racing scroll-view layout.
                        transcriptText
                            .frame(height: 36, alignment: .bottom)
                            .clipped()
                            // Clipping only affects drawing; overflowing text must not cover controls.
                            .allowsHitTesting(false)
                    }
                }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
        .onChange(of: model.isPresented) {
            if model.isPresented { isExpanded = false }
        }
    }

    private var transcriptText: some View {
        // Only the latest two lines are visible. Do not lay out an entire day-long session.
        Text(model.previewTranscript.isEmpty ? emptyText : String(model.previewTranscript.suffix(4_096)))
            .font(.system(size: 13))
            .lineSpacing(4)
            .foregroundStyle(model.previewTranscript.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .transaction { $0.animation = nil }
    }

    private var cleanupHelp: String {
        if model.isCleaningText {
            return "Cleaning the current stopped transcript with OpenAI."
        }
        if model.canUndoCleanup {
            return "Restore and copy the original text. Available until Resume, Reset, Clear, or Close. Undo does not require an OpenAI key."
        }
        if !model.hasCleanupKey {
            return "Add an OpenAI API key in Settings → General before cleaning."
        }
        if model.active {
            return "Pause & copy before cleaning the text."
        }
        if model.isClosing {
            return "Cleanup is unavailable while dictation is closing."
        }
        return "Send the current stopped transcript to OpenAI for cleanup, update this saved session, and copy it. Internet and OpenAI usage charges apply."
    }

    private var cleanupActionAvailable: Bool {
        !model.isCleaningText && (model.canUndoCleanup || model.canCleanText)
    }

    private var emptyText: String {
        switch model.state {
        case .starting: "Connecting… Your words will appear here."
        case .recording: "Listening… Your words will appear here."
        case .finalizing: "Finishing transcription…"
        case .idle, .paused: "Use Start or Resume to dictate, then Pause & copy."
        }
    }
}

private struct FollowingTranscriptView: NSViewRepresentable {
    let text: String
    let isPlaceholder: Bool
    let latestRequest: Int

    func makeNSView(context: Context) -> FollowingTranscriptScrollView {
        FollowingTranscriptScrollView()
    }

    func updateNSView(_ view: FollowingTranscriptScrollView, context: Context) {
        view.update(text: text, isPlaceholder: isPlaceholder, latestRequest: latestRequest)
    }
}

private final class FollowingTranscriptScrollView: NSScrollView {
    private let transcriptView = NSTextView()
    private var latestRequest = 0
    private var laidOutWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        transcriptView.isEditable = false
        transcriptView.isSelectable = false
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = .zero
        transcriptView.textContainer?.lineFragmentPadding = 0
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        documentView = transcriptView
    }

    required init?(coder: NSCoder) { nil }

    private var isAtBottom: Bool {
        transcriptView.frame.height - contentView.bounds.maxY <= 2
    }

    func update(text: String, isPlaceholder: Bool, latestRequest: Int) {
        // Read the OLD extent before replacing text; growth must not look like scrolling up.
        let follow = isAtBottom || latestRequest != self.latestRequest
        self.latestRequest = latestRequest
        if transcriptView.string != text {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            transcriptView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraph,
                .foregroundColor: isPlaceholder ? NSColor.secondaryLabelColor : NSColor.labelColor
            ]))
        }
        sizeDocument()
        if follow { scrollToBottom() }
    }

    override func layout() {
        let follow = isAtBottom
        super.layout()
        if laidOutWidth != contentSize.width {
            sizeDocument()
            if follow { scrollToBottom() }
        }
    }

    private func sizeDocument() {
        guard contentSize.width > 0,
              let container = transcriptView.textContainer,
              let manager = transcriptView.layoutManager else { return }
        laidOutWidth = contentSize.width
        transcriptView.setFrameSize(NSSize(width: laidOutWidth, height: transcriptView.frame.height))
        container.containerSize = NSSize(width: laidOutWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        transcriptView.setFrameSize(NSSize(
            width: laidOutWidth,
            height: max(contentSize.height, ceil(manager.usedRect(for: container).height))
        ))
    }

    private func scrollToBottom() {
        contentView.scroll(to: NSPoint(x: 0, y: max(0, transcriptView.frame.height - contentSize.height)))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
final class RecordingBarController {
    private let model: TranscriptionCoordinator
    private var openSetup: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var panel: RecordingPanel?
    private var contentHeight = RecordingBarMetrics.compactHeight
    private var preferredScreen: NSScreen?
    private var transitionGeneration = 0
    private var layoutScheduled = false
    private var isShutdown = false

    init(model: TranscriptionCoordinator, openSetup: @escaping () -> Void) {
        self.model = model
        self.openSetup = openSetup
        observeModel()
        observeScreens()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        transitionGeneration &+= 1
        cancellables.removeAll()

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        preferredScreen = nil
        openSetup = nil
    }

    private func observeModel() {
        model.$isPresented
            .removeDuplicates()
            .sink { [weak self] isPresented in
                Task { @MainActor [weak self] in
                    self?.applyPresentation(isPresented)
                }
            }
            .store(in: &cancellables)
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.preferredScreen = nil
                self.updatePanelFrame()
            }
        }
    }

    private func applyPresentation(_ isPresented: Bool) {
        guard !isShutdown, isPresented == model.isPresented else { return }
        if isPresented {
            showPanel()
        } else {
            hidePanel()
        }
    }

    private func showPanel() {
        let panel = makePanelIfNeeded()
        transitionGeneration &+= 1
        preferredScreen = screenUnderPointer() ?? panel.screen ?? NSScreen.main
        updatePanelFrame()

        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        transitionGeneration &+= 1
        let hideGeneration = transitionGeneration

        guard !reduceMotion else {
            panel.orderOut(nil)
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RecordingBarMetrics.hideDuration))
            guard let self,
                  !self.isShutdown,
                  self.transitionGeneration == hideGeneration,
                  !self.model.isPresented,
                  let panel = self.panel else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanelIfNeeded() -> RecordingPanel {
        if let panel { return panel }

        let panel = RecordingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: RecordingBarMetrics.width,
                height: RecordingBarMetrics.compactHeight
            )
        )
        let hostingView = FirstClickHostingView(
            rootView: RecordingBarView(
                model: model,
                openSetup: { [weak self] in self?.openSetup?() },
                onSizeChange: { [weak self] size in
                    guard let self else { return }
                    self.contentHeight = size.height.rounded(.up)
                    self.scheduleLayout()
                }
            )
        )
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: RecordingBarMetrics.width, height: RecordingBarMetrics.compactHeight)
        )
        hostingView.autoresizingMask = [.width, .height]
        // SwiftUI reports actual card geometry; AppKit must not impose size limits.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    private func scheduleLayout() {
        guard !isShutdown, model.isPresented, !layoutScheduled else { return }
        layoutScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.layoutScheduled = false
            guard !self.isShutdown, self.model.isPresented, self.panel?.isVisible == true else { return }
            self.updatePanelFrame()
        }
    }

    private func updatePanelFrame() {
        guard let panel else { return }
        let screen = usableScreen()
        let size = fittingPanelSize(on: screen)
        let visibleFrame = screen.visibleFrame
        let x = min(
            max(visibleFrame.minX + RecordingBarMetrics.horizontalMargin, visibleFrame.midX - size.width / 2),
            visibleFrame.maxX - size.width - RecordingBarMetrics.horizontalMargin
        )
        let y = visibleFrame.minY + RecordingBarMetrics.verticalMargin
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func usableScreen() -> NSScreen {
        if let preferredScreen,
           NSScreen.screens.contains(where: { $0 === preferredScreen }) {
            return preferredScreen
        }
        let screen = screenUnderPointer() ?? panel?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        preferredScreen = screen
        return screen
    }

    private func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
    }

    private func fittingPanelSize(on screen: NSScreen) -> NSSize {
        let maximumHeight = max(
            RecordingBarMetrics.compactHeight,
            screen.visibleFrame.height - RecordingBarMetrics.verticalMargin * 2
        )
        let height = min(max(RecordingBarMetrics.compactHeight, contentHeight), maximumHeight)
        return NSSize(width: RecordingBarMetrics.width, height: height)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private final class RecordingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // SwiftUI animates the card; native window ordering stays immediate.
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MicrophoneIndicator: View {
    let isCapturing: Bool
    let isError: Bool
    let reduceMotion: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            if isCapturing {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 28, height: 28)
                    .scaleEffect(reduceMotion ? 1 : (pulse ? 1 : 0.72))
            }

            Circle()
                .fill(indicatorColor.opacity(isCapturing ? 0.18 : 0.12))
                .frame(width: 28, height: 28)

            Image(systemName: isCapturing ? "mic.fill" : isError ? "exclamationmark" : "mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(indicatorColor)
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(isCapturing ? "Microphone on" : "Microphone off")
        .onAppear(perform: updatePulse)
        .onChange(of: isCapturing) { _, _ in
            updatePulse()
        }
        .onChange(of: reduceMotion) { _, _ in
            updatePulse()
        }
    }

    private var indicatorColor: Color {
        if isCapturing || isError { return .red }
        return .secondary
    }

    private func updatePulse() {
        guard isCapturing, !reduceMotion else {
            pulse = false
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

private struct RecordingBarPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 6)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white : Color.black)
                        .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            }
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecordingBarSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed && isEnabled ? 0.14 : 0.08))
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecordingBarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = .secondary
    var hoverTint: Color?
    @State private var isHovered = false

    private var activeTint: Color {
        isHovered ? (hoverTint ?? tint) : tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? activeTint : Color.secondary.opacity(0.45))
            .background {
                Circle()
                    .fill(isEnabled
                          ? activeTint.opacity(configuration.isPressed ? 0.24 : isHovered ? 0.17 : 0.09)
                          : Color.primary.opacity(0.04))
            }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}

private enum RecordingBarVisualState: Equatable {
    case idle
    case starting
    case recording
    case finalizing
    case paused
    case closing
    case error
}

private enum RecordingBarMetrics {
    static let width: CGFloat = 520
    static let compactHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 18
    static let horizontalMargin: CGFloat = 20
    static let verticalMargin: CGFloat = 22
    static let showDuration: TimeInterval = 0.18
    static let hideDuration: TimeInterval = 0.14
}
