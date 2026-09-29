// AboutMoonlightView.swift
//
// The About Moonlight window. It shows the app icon and name with a rotating light-hearted
// tagline, and links to the website, the feedback form and the Moonlight community on Reddit.

import SwiftUI

struct AboutMoonlightView: View {
    @Environment(\.dismiss) private var dismiss

    let showFeedback: () -> Void
    @State private var taglineIndex = Int.random(in: 0..<taglines.count)

    private static let taglines = [
        "Streaming services hate this one simple trick.",
        "Software, not as a service.",
        "Finally, an app that won’t charge you $1 more every year.",
        "Your music collection misses you.",
        "Like social media, but without the social.",
        "Owning your own music? What a novel concept."
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Moonlight")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.textPrimary)

                Text(Self.taglines[taglineIndex])
                    .id(taglineIndex)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: taglineIndex)
            }
            .padding(.top, 32)
            .padding(.bottom, 26)

            Divider().overlay(Color.borderSoft)

            VStack(spacing: 2) {
                Link(destination: URL(string: "https://moonlightapp.org")!) {
                    AboutLinkRow(title: "Visit our website", systemImage: "globe", opensExternally: true)
                }

                Button(action: showFeedback) {
                    AboutLinkRow(title: "Send feedback", systemImage: "bubble.left.and.bubble.right", opensExternally: false)
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: "https://www.reddit.com/r/moonlightapp/")!) {
                    AboutLinkRow(title: "Join the Moonlight community on Reddit", systemImage: "person.3", opensExternally: true)
                }
            }
            .padding(16)

            Divider().overlay(Color.borderSoft)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .background(Color.bgContent)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                taglineIndex = (taglineIndex + 1) % Self.taglines.count
            }
        }
    }
}

private struct AboutLinkRow: View {
    let title: String
    let systemImage: String
    let opensExternally: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(Color.dAccent)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Image(systemName: opensExternally ? "arrow.up.right" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
