// ContactFeedbackView.swift
//
// The Contact / Send Feedback form. The user types a message and can optionally add an email
// address if they want a reply, then sends it to the Moonlight team. The same form is reused for
// suggesting a new color theme and for reporting a problem with a radio station, where the
// station's name, IDs and stream address are added to the message automatically. It shows an
// error if sending fails.

import SwiftUI

enum ContactFeedbackTopic {
    case general
    case themeSuggestion
    case radioStation(RadioStation)

    var title: String {
        switch self {
        case .general: "Contact / Send Feedback"
        case .themeSuggestion: "Suggest a Theme"
        case .radioStation: "Report a Problem with a Station"
        }
    }

    var introduction: String {
        switch self {
        case .general:
            "Have a concern, question, or feedback? Send us a note."
        case .themeSuggestion:
            "Share an original palette or aesthetic you’d love to see in Moonlight. Aim for something broadly appealing, and avoid copies of existing branded or copyrighted themes."
        case .radioStation(let station):
            "Tell us what’s wrong with “\(station.name.singleLineText)”: it won’t play, it’s the wrong station, or its details are wrong. The station’s name, IDs and stream address are included with your report so we can fix it."
        }
    }

    var messageLabel: String {
        switch self {
        case .general: "Message"
        case .themeSuggestion: "Your theme idea"
        case .radioStation: "What’s wrong?"
        }
    }

    var submissionPrefix: String {
        switch self {
        case .general:
            return ""
        case .themeSuggestion:
            return "[Theme suggestion]\n\n"
        case .radioStation(let station):
            let details: [String?] = [
                "Station: \(station.name)",
                "Station ID: \(station.stationUUID)",
                station.channelID.map { "Channel ID: \($0)" },
                "Stream: \(station.streamURL)",
                station.countryCode.map { "Country: \($0)" }
            ]
            let lines = ["[Station report]"] + details.compactMap { $0?.singleLineText }
            return lines.joined(separator: "\n") + "\n\n"
        }
    }
}

struct ContactFeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var message = ""
    @State private var isSending = false
    @State private var statusMessage: String?

    private let service: ContactService
    private let topic: ContactFeedbackTopic
    private let onSubmissionSuccess: () -> Void

    init(
        topic: ContactFeedbackTopic = .general,
        service: ContactService = ContactService(),
        onSubmissionSuccess: @escaping () -> Void = {}
    ) {
        self.topic = topic
        self.service = service
        self.onSubmissionSuccess = onSubmissionSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.borderSoft)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(topic.introduction)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)

                    form

                    if !ContactService.isConfigured {
                        Label(ContactServiceError.notConfigured.errorDescription ?? "", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                    }

                    if let statusMessage {
                        Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(statusMessage)
                    }
                }
                .padding(20)
            }
            .background(Color.bgContent)

            Divider().overlay(Color.borderSoft)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text(topic.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            ContactField(label: "Email (optional — if you’d like a response)") {
                TextField("If you’d like a reply", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Email, optional")
            }

            ContactField(label: topic.messageLabel) {
                TextEditor(text: $message)
                    .font(.system(size: 12))
                    .frame(minHeight: 150)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .scrollContentBackground(.hidden)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                            .stroke(Color.borderSoft, lineWidth: 1)
                    )
                    .accessibilityLabel(topic.messageLabel)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSending)

            Button(action: submit) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                } else {
                    Text("Send Feedback")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSending || !ContactService.isConfigured)
            .accessibilityHint("Sends the optional email address and message entered above.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func submit() {
        statusMessage = nil
        isSending = true

        Task {
            do {
                try await service.submit(email: email, message: message, prefix: topic.submissionPrefix)
                dismiss()
                onSubmissionSuccess()
            } catch let error as ContactServiceError {
                statusMessage = error.localizedDescription
            } catch {
                statusMessage = "We couldn't send your feedback. Check your internet connection and try again."
            }
            isSending = false
        }
    }
}

private struct ContactField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            content
        }
    }
}
