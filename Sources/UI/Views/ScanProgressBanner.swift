// ScanProgressBanner.swift
//
// The small floating banner at the top of the window while Moonlight scans the music folder. It
// shows progress and counts (scanned, skipped, missing, relinked, removed), then reports when
// the scan is complete or the folder could not be reached. Any errors appear as a badge that can
// be clicked for details.

import SwiftUI

struct ScanProgressBanner: View {
    let summary: ScanSummary
    let isCompleted: Bool
    let onDismiss: (() -> Void)?
    let onErrorTap: (() -> Void)?

    @State private var spinAngle: Double = 0

    private var failed: Bool { isCompleted && summary.failed }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: failed ? "externaldrive.badge.exclamationmark" : (isCompleted ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(failed ? .orange : (isCompleted ? .green : .accentColor))
                .rotationEffect(.degrees(isCompleted ? 0 : spinAngle))
                .onAppear {
                    guard !isCompleted else { return }
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        spinAngle = 360
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(failed ? "Music folder unavailable" : (isCompleted ? "Scan complete" : "Analyzing library"))
                    .font(.system(size: 13, weight: .semibold))
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .animation(.default, value: summary.processedFiles)
            }

            if summary.errorCount > 0 {
                if let onErrorTap {
                    Button(action: onErrorTap) {
                        errorLabel
                    }
                    .buttonStyle(.plain)
                } else {
                    errorLabel
                }
            }

            if isCompleted, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(white: 0.14), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .padding(.top, 10)
    }

    private var errorLabel: some View {
        Label("\(summary.errorCount) \(summary.errorCount == 1 ? "error" : "errors")",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.12), in: Capsule())
    }

    private var countLabel: String {
        if let failureMessage = summary.failureMessage {
            return failureMessage
        }
        let parts = [
            "\(summary.processedFiles) scanned",
            summary.skippedFiles > 0 ? "\(summary.skippedFiles) skipped" : nil,
            summary.missingFiles > 0 ? "\(summary.missingFiles) missing" : nil,
            summary.relinkedFiles > 0 ? "\(summary.relinkedFiles) relinked" : nil,
            summary.removedFiles > 0 ? "\(summary.removedFiles) removed" : nil
        ].compactMap { $0 }

        if isCompleted {
            return parts.joined(separator: " · ")
        }
        return summary.totalFiles > 0
            ? "\(summary.processedFiles + summary.skippedFiles) of \(summary.totalFiles) checked"
            : parts.joined(separator: " · ")
    }
}
