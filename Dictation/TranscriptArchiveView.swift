import AppKit
import Foundation
import SwiftUI

struct TranscriptArchiveView: View {
    @ObservedObject var archive: TranscriptArchive

    @State private var selectedSessionID: UUID?
    @State private var selectedSessionExpired = false
    @State private var copyFeedback: CopyFeedback?
    @State private var loadedSessionID: UUID?
    @State private var selectedText: String?

    var body: some View {
        HStack(spacing: 0) {
            sessionsList
            Divider()
            sessionDetail
        }
        .frame(minHeight: 300, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onChange(of: archive.sessions) { _, sessions in
            guard let selectedSessionID,
                  !sessions.contains(where: { $0.id == selectedSessionID })
            else { return }

            self.selectedSessionID = nil
            selectedSessionExpired = true
            copyFeedback = nil
        }
        .onChange(of: selectedSessionID) { _, newValue in
            guard newValue != nil else { return }
            selectedSessionExpired = false
            copyFeedback = nil
        }
        .onChange(of: selectedSession) { _, session in
            loadedSessionID = session?.id
            selectedText = session.flatMap { archive.text(for: $0.id) }
        }
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions")
                    .font(.headline)
                Text(archive.sessions.isEmpty ? "No saved sessions" : "Newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if archive.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No archived transcripts")
                        .font(.callout.weight(.medium))
                    Text("Stable completed text will appear here after Pause & copy or Copy & close.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List(selection: $selectedSessionID) {
                    ForEach(archive.sessions) { session in
                        ArchiveSessionRow(session: session)
                            .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            if let errorMessage = archive.errorMessage {
                archiveError(message: errorMessage)
                    .padding(10)
            }
        }
        .frame(minWidth: 205, idealWidth: 230, maxWidth: 270, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let session = selectedSession {
            if loadedSessionID == session.id, let text = selectedText {
                selectedSessionDetail(session: session, text: text)
            } else {
                unavailableTextDetail
            }
        } else if selectedSessionExpired {
            expiredSessionDetail
        } else {
            VStack(spacing: 9) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Select a session")
                    .font(.callout.weight(.medium))
                Text("Its complete, stable transcript will stay selectable here until its retention period ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedSession: TranscriptSummary? {
        guard let selectedSessionID else { return nil }
        return archive.sessions.first { $0.id == selectedSessionID }
    }

    private func selectedSessionDetail(session: TranscriptSummary, text: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcript")
                        .font(.headline)
                    Text(TranscriptArchivePresentation.date(session.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    copy(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            sessionMetadata(session)

            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .scrollIndicators(.automatic)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityLabel("Archived transcript text")

            if let copyFeedback {
                Label(copyFeedback.message, systemImage: copyFeedback.symbol)
                    .font(.caption)
                    .foregroundStyle(copyFeedback.isFailure ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sessionMetadata(_ session: TranscriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Started \(TranscriptArchivePresentation.date(session.startedAt))")
            Text("Last updated \(TranscriptArchivePresentation.date(session.updatedAt))")
            Text("Duration \(TranscriptArchivePresentation.duration(session.duration))")
            Text("Language \(session.language ?? "Automatic")")
            if session.isIncomplete {
                Label("Incomplete — only stable text received before the interruption is retained.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var unavailableTextDetail: some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Transcript text unavailable")
                .font(.callout.weight(.medium))
            Text("The session summary remains, but its full text is no longer available to copy. Check the archive message for storage details.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expiredSessionDetail: some View {
        VStack(spacing: 9) {
            Image(systemName: "clock.badge.xmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Session expired")
                .font(.callout.weight(.medium))
            Text("This transcript reached its automatic deletion date while Hot Mic was running and is no longer available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func archiveError(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Transcript archive needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if pasteboard.setString(text, forType: .string) {
            copyFeedback = CopyFeedback(message: "Copied to the clipboard.", isFailure: false)
        } else {
            copyFeedback = CopyFeedback(
                message: "Clipboard write failed. Select the text and copy it manually.",
                isFailure: true
            )
        }
    }
}

private struct ArchiveSessionRow: View {
    let session: TranscriptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(TranscriptArchivePresentation.date(session.updatedAt))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if session.isIncomplete {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Incomplete session")
                }
            }

            Text(session.preview.isEmpty ? "No stable text" : session.preview)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(TranscriptArchivePresentation.duration(session.duration))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct CopyFeedback {
    let message: String
    let isFailure: Bool

    var symbol: String {
        isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }
}

private enum TranscriptArchivePresentation {
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ interval: Double) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
