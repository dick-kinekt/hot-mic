import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    enum Section: CaseIterable, Hashable, Identifiable {
        case general
        case speech
        case privacy
        case transcripts
        case session
        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .speech: "Speech"
            case .privacy: "Privacy"
            case .transcripts: "Transcripts"
            case .session: "Session"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Connection, microphone, and shortcut readiness."
            case .speech: "Language and vocabulary hints for the next recording."
            case .privacy: "How audio and text are handled by the provider."
            case .transcripts: "Saved local transcript text and automatic deletion."
            case .session: "The current dictation, live controls, and timings."
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .speech: "waveform"
            case .privacy: "hand.raised"
            case .transcripts: "text.book.closed"
            case .session: "mic"
            }
        }
    }

    private enum FocusedField: Hashable {
        case apiKey
    }

    @ObservedObject var model: TranscriptionCoordinator
    @ObservedObject var settings: DictationSettings
    @ObservedObject var archive: TranscriptArchive
    @ObservedObject var shortcuts: RecordingShortcutController

    @Environment(\.colorScheme) private var colorScheme
    @State private var apiKey = ""
    @State private var selectedSection: Section?
    @State private var showsRemoveKeyConfirmation = false
    @State private var retentionDaysInput: String
    @State private var retentionInputError: String?
    @State private var pendingRetentionDays: Int?
    @State private var showsRetentionReductionConfirmation = false
    @FocusState private var focusedField: FocusedField?

    private static let privacyGuidanceURL = URL(string: "https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models")!

    init(
        model: TranscriptionCoordinator,
        settings: DictationSettings,
        archive: TranscriptArchive,
        shortcuts: RecordingShortcutController,
        initialSection: Section = .general
    ) {
        self.model = model
        self.settings = settings
        self.archive = archive
        self.shortcuts = shortcuts
        _selectedSection = State(initialValue: initialSection)
        _retentionDaysInput = State(initialValue: String(settings.transcriptRetentionDays))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .background(backgroundColor)
        .confirmationDialog(
            "Remove saved API key?",
            isPresented: $showsRemoveKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) {
                apiKey = ""
                model.deleteKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the ElevenLabs API key from macOS Keychain. You will need to enter it again before recording.")
        }
        .confirmationDialog(
            "Reduce transcript retention?",
            isPresented: $showsRetentionReductionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply Shorter Retention", role: .destructive) {
                if let pendingRetentionDays {
                    applyRetentionDays(pendingRetentionDays)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRetentionDays = nil
                retentionDaysInput = String(settings.transcriptRetentionDays)
            }
        } message: {
            Text("Reducing retention can permanently delete saved transcripts that are already older than the new \(pendingRetentionDays ?? settings.transcriptRetentionDays)-day limit.")
        }
        .onAppear {
            model.refreshPermissions()
            retentionDaysInput = String(settings.transcriptRetentionDays)
        }
        .onChange(of: settings.transcriptRetentionDays) { _, days in
            if !showsRetentionReductionConfirmation {
                retentionDaysInput = String(days)
            }
        }
        .onDisappear {
            apiKey = ""
            focusedField = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            apiKey = ""
            focusedField = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Hot Mic")
                        .font(.system(size: 16, weight: .semibold))
                    Text("by Kinekt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Text("For the record.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()

            VStack(spacing: 4) {
                ForEach(Section.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol).frame(width: 18)
                            Text(section.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                        .foregroundStyle(selectedSection == section ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(
                            selectedSection == section ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(sidebarColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hot Mic settings sections")
    }

    @ViewBuilder
    private var detail: some View {
        if activeSection == .transcripts {
            transcriptDetail
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader
                    sectionContent
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: activeSection.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(recordAccent)
                .frame(width: 42, height: 42)
                .background(recordAccent.opacity(colorScheme == .dark ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(activeSection.title)
                    .font(.system(size: 24, weight: .bold))
                Text(activeSection.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch activeSection {
        case .general:
            generalContent
        case .speech:
            speechContent
        case .privacy:
            privacyContent
        case .transcripts:
            EmptyView()
        case .session:
            sessionContent
    }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isError {
                Label(model.notice, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canStart {
                SettingsCard("You're ready", detail: "Your microphone, connection, and privacy choices are set.") {
                    HStack {
                        Text("Use your shortcut from any app.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isPresented ? "Open Session" : "Start Dictation") {
                            if model.isPresented { selectedSection = .session } else { model.start() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(recordAccent)
                    }
                }
            } else {
            SettingsCard("Ready to record", detail: "Finish the items below before starting a dictation.") {
                VStack(spacing: 0) {
                    ReadinessRow(
                        title: "Privacy guidance",
                        detail: settings.privacyReviewed ? "Reviewed for future recordings." : "Review the provider training and retention guidance.",
                        isComplete: settings.privacyReviewed
                    ) {
                        if settings.privacyReviewed {
                            Text("Ready")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Review") { selectedSection = .privacy }
                                .buttonStyle(.borderless)
                                .disabled(model.active)
                        }
                    }

                    Divider().padding(.leading, 29)

                    ReadinessRow(
                        title: "ElevenLabs API key",
                        detail: model.hasKey ? "Stored securely in macOS Keychain." : "Save a key below to enable recording.",
                        isComplete: model.hasKey
                    ) {
                        if model.hasKey {
                            Text("Ready")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Add Key") { focusedField = .apiKey }
                                .buttonStyle(.borderless)
                                .disabled(model.active)
                        }
                    }

                    Divider().padding(.leading, 29)

                    ReadinessRow(
                        title: "Microphone",
                        detail: model.microphoneAllowed ? "Access is allowed." : "Allow access before starting a dictation.",
                        isComplete: model.microphoneAllowed
                    ) {
                        if model.microphoneAllowed {
                            Text("Allowed")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Allow") {
                                Task { await model.requestMicrophone() }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.active)
                        }
                    }

                    Divider().padding(.leading, 29)

                    ReadinessRow(
                        title: "Speech settings",
                        detail: settings.vocabularyValid ? "Vocabulary hints are valid." : "Correct the vocabulary hint limits.",
                        isComplete: settings.vocabularyValid
                    ) {
                        if settings.vocabularyValid {
                            Text("Ready")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Review") { selectedSection = .speech }
                                .buttonStyle(.borderless)
                                .disabled(model.active)
                        }
                    }
                }
            }
            }

            SettingsCard("Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        SecureField(
                            model.hasKey ? "Replace saved ElevenLabs API key" : "ElevenLabs API key",
                            text: $apiKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .privacySensitive()
                        .focused($focusedField, equals: .apiKey)
                        .accessibilityIdentifier("api-key")
                        .accessibilityLabel(model.hasKey ? "Replacement ElevenLabs API key" : "ElevenLabs API key")
                        .onSubmit(saveAPIKey)

                        Button(model.hasKey ? "Replace Key" : "Save Key", action: saveAPIKey)
                            .buttonStyle(.borderedProminent)
                            .tint(recordAccent)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(model.hasKey ? "A key is stored in macOS Keychain." : "No key saved. Enter it here, never in chat or a source file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 12)

                        if model.hasKey {
                            Button("Remove Key") {
                                showsRemoveKeyConfirmation = true
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
                .disabled(model.active)
            }

            SettingsCard("Microphone") {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: model.microphoneAllowed ? "checkmark.circle.fill" : "mic.slash")
                        .foregroundStyle(model.microphoneAllowed ? Color.green : Color.secondary)
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.microphoneAllowed ? "Microphone allowed" : "Microphone not allowed")
                            .font(.body.weight(.medium))
                        Text(model.microphoneAllowed ? "Audio is captured only when you start recording." : "If access was denied, enable Hot Mic in System Settings → Privacy & Security → Microphone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button(model.microphoneAllowed ? "Allowed" : "Allow Microphone") {
                            Task { await model.requestMicrophone() }
                        }
                        .disabled(model.microphoneAllowed)
                        if !model.microphoneAllowed {
                            Link("System Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                .font(.caption)
                        }
                    }
                }
                .disabled(model.active)
            }

            SettingsCard("Recording shortcut") {
                VStack(alignment: .leading, spacing: 9) {
                    KeyboardShortcuts.Recorder("Shortcut", name: .recordDictation)
                        .disabled(model.active)

                    Text(shortcuts.shortcutLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Press once to start; press again to cancel and dismiss. Releasing the keys does not stop recording. Use Pause or Close in the bar to finish and copy instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.active {
                Text("Connection, microphone, speech, privacy, and shortcut settings stay fixed while a stream is active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var speechContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard("Language") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Transcription language", selection: $settings.language) {
                        Text("Automatic").tag("")
                        Text("English").tag("en")
                        Text("Dutch").tag("nl")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Transcription language")

                    Text("Automatic lets ElevenLabs determine the spoken language. Choose English or Dutch when you want to send a specific language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(model.active)
            }

            SettingsCard("Vocabulary hints", detail: "Optional. Add one word or phrase per line.") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $settings.vocabulary)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 132, maxHeight: 180)
                        .padding(8)
                        .background(editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(vocabularyValidationColor.opacity(0.45), lineWidth: 1)
                        }
                        .accessibilityLabel("Vocabulary hints")

                    Text(vocabularyValidationText)
                        .font(.caption)
                        .foregroundStyle(vocabularyValidationColor)

                    Text("Keyterm prompting costs extra; hints do not guarantee spelling or rewrite commands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(model.active)
            }
        }
    }

    private var privacyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard("Before recording") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio streams directly to ElevenLabs while you dictate. Hot Mic stores stable completed transcript text locally in its archive, but saves no audio files and sends no analytics. Dictation can incur ElevenLabs usage charges.")
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Before real use: in your ElevenLabs account, open Terms and privacy → Data use and turn off ‘Improve the models for everyone’. Opt-out covers future submissions; it is not zero retention.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link("Read ElevenLabs training opt-out instructions", destination: Self.privacyGuidanceURL)
                        .font(.callout.weight(.medium))

                    Toggle("I reviewed the privacy and training opt-out guidance", isOn: $settings.privacyReviewed)
                        .toggleStyle(.switch)
                }
                .disabled(model.active)
            }

            SettingsCard("Retention request") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Request zero retention (eligible enterprise accounts only)", isOn: $settings.zeroRetention)
                        .toggleStyle(.switch)

                    Text(zeroRetentionExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(model.active)
            }
        }
    }

    private var transcriptDetail: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                detailHeader
                transcriptContent
            }
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard("Automatic deletion", detail: "Transcript text is stored locally on this Mac. Audio is never archived.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Keep transcripts for")
                        TextField("Days", text: $retentionDaysInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 62)
                            .accessibilityLabel("Transcript retention days")
                        Text("days")
                            .foregroundStyle(.secondary)
                        Button("Apply", action: requestRetentionDaysChange)
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                    }

                    Text("Enter a whole number from 1 to 3,650. Expired transcripts are deleted automatically while Hot Mic is running. If the app is closed when they expire, it deletes them on the next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let retentionInputError {
                        Label(retentionInputError, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            TranscriptArchiveView(archive: archive)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard("Recording") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: model.capturing ? "mic.fill" : "mic")
                            .foregroundStyle(model.capturing ? recordAccent : Color.secondary)
                            .font(.title3)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.state.rawValue)
                                .font(.body.weight(.semibold))
                            Text(model.capturing ? "Microphone on" : "Microphone off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Text(elapsedTime)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Elapsed recording time \(elapsedTime)")
                    }

                    HStack(spacing: 9) {
                        if model.state == .starting || model.state == .recording {
                            Button("Pause & Copy", action: model.pause)
                                .buttonStyle(.borderedProminent)
                                .tint(recordAccent)
                        } else if model.state != .finalizing {
                            Button(model.isPresented ? "Continue Dictation" : "Start Dictation", action: model.start)
                                .buttonStyle(.borderedProminent)
                                .tint(recordAccent)
                                .disabled(!canStart)
                        }

                        if model.isPresented {
                            Button("Finish & Close", action: model.close)
                                .disabled(model.isClosing)
                        }

                        if model.isClosing || model.state == .finalizing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Finishing dictation")
                        }
                    }

                    Text(model.notice)
                        .font(.callout)
                        .foregroundStyle(model.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let archiveError = archive.errorMessage {
                        Label("Transcript archive: \(archiveError)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }


            SettingsCard("Current dictation", detail: "Stable committed text is retained in Transcripts.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.transcript.isEmpty ? "Completed text appears here after you pause. Continue appends to this dictation; stable committed text is archived separately." : model.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .padding(10)
                        .background(editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Current dictation result")

                    HStack(spacing: 9) {
                        Button("Copy Result", action: model.copyResult)
                            .disabled(model.transcript.isEmpty)

                        Button("Clear Result", role: .destructive, action: model.clearResult)
                            .disabled(model.active || model.transcript.isEmpty)

                        Spacer(minLength: 12)

                        if let language = model.detectedLanguage {
                            Text("Language: \(language)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Pausing copies the complete dictation to your clipboard. Closing while recording finishes and copies before dismissing. Resetting or cancelling clears the live session, but keeps already archived stable text; provisional hypotheses are never retained. No automatic paste or Return is sent; clipboard managers may retain copied text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup("Performance details") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Each recording segment pauses automatically after 24 hours. Paused time is not recorded. Short final segments are padded with silence for provider processing after the microphone is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 118), spacing: 10)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        TimingMetric("Mic start", value: model.microphoneStartMS)
                        TimingMetric("First audio", value: model.firstAudioMS)
                        TimingMetric("Connection", value: model.connectionMS)
                        TimingMetric("Stop → result", value: model.resultMS)
                    }
                }
            }
        }
    }

    private func requestRetentionDaysChange() {
        let trimmedInput = retentionDaysInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = Int(trimmedInput), (1...3_650).contains(days) else {
            retentionInputError = "Enter a whole number from 1 to 3,650 days."
            return
        }

        retentionInputError = nil
        if days < settings.transcriptRetentionDays {
            pendingRetentionDays = days
            showsRetentionReductionConfirmation = true
        } else {
            applyRetentionDays(days)
        }
    }

    private func applyRetentionDays(_ days: Int) {
        settings.transcriptRetentionDays = days
        retentionDaysInput = String(days)
        retentionInputError = nil
        pendingRetentionDays = nil
    }

    private var activeSection: Section {
        selectedSection ?? .general
    }

    private var canStart: Bool {
        settings.privacyReviewed && model.hasKey && model.microphoneAllowed && settings.vocabularyValid
    }

    private var elapsedTime: String {
        let totalSeconds = max(0, Int(model.recordingSeconds.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var vocabularyValidationText: String {
        let count = settings.keyterms.count
        if settings.vocabularyValid {
            return "\(count) of 50 vocabulary hints used. Each hint is 20 characters or fewer."
        }
        if count > 50 {
            return "\(count) vocabulary hints entered. Use at most 50, with each hint 20 characters or fewer."
        }
        return "One or more hints are longer than 20 characters. Shorten each hint to continue."
    }

    private var vocabularyValidationColor: Color {
        settings.vocabularyValid ? .secondary : .red
    }

    private var zeroRetentionExplanation: String {
        settings.zeroRetention
            ? "Sends enable_logging=false. If your account rejects it, dictation fails; no silent fallback. This provider request does not change local transcript history."
            : "Ordinary provider retention applies. Account settings and enterprise eligibility have not been verified by this app. Provider retention does not control local transcript history."
    }

    private var recordAccent: Color {
        Color(red: 0.8, green: 0.18, blue: 0.2)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.075, blue: 0.085)
            : Color(red: 0.965, green: 0.965, blue: 0.975)
    }

    private var sidebarColor: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.1)
            : Color(red: 0.94, green: 0.94, blue: 0.955)
    }

    private var editorBackground: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.08)
            : Color.white.opacity(0.62)
    }

    private func saveAPIKey() {
        guard !model.active, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.saveKey(apiKey) {
            apiKey = ""
            focusedField = nil
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let detail: String?
    let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.1), lineWidth: 1)
        }
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.12)
            : Color(red: 0.995, green: 0.995, blue: 1)
    }
}

private struct ReadinessRow<Accessory: View>: View {
    let title: String
    let detail: String
    let isComplete: Bool
    let accessory: Accessory

    init(
        title: String,
        detail: String,
        isComplete: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory
                .font(.callout.weight(.medium))
        }
        .padding(.vertical, 10)
    }
}

private struct TimingMetric: View {
    let name: String
    let value: Double?

    init(_ name: String, value: Double?) {
        self.name = name
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f ms", $0) } ?? "—")
                .font(.system(.body, design: .monospaced).weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
