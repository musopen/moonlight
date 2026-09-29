// ScanErrorsView.swift
//
// The list of files that failed to import during the last library scan, used both in Settings
// and in a pop-up window. Each entry shows the file name, what went wrong, and a button to show
// the file in Finder if it still exists.

import AppKit
import SwiftUI

struct ScanErrorsView: View {
    let errors: [ScanErrorItem]

    var body: some View {
        if errors.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.textTertiary)
                Text("No errors from last scan")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgContent)
        } else {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(errors) { error in
                        ErrorRow(error: error)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color.bgContent)
        }
    }
}

private struct ErrorRow: View {
    let error: ScanErrorItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange.opacity(0.8))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: error.fileURL)?.lastPathComponent ?? error.fileURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text("\(error.stage) · \(error.category)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.82))
                    .lineLimit(1)
                Text(error.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(2)
            }

            Spacer()

            if canReveal {
                Button {
                    reveal()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textTertiary)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(isHovered ? Color.bgHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(error.fileURL)
    }

    private var canReveal: Bool {
        guard let url = URL(string: error.stableFileURL.isEmpty ? error.fileURL : error.stableFileURL) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func reveal() {
        guard let url = URL(string: error.stableFileURL.isEmpty ? error.fileURL : error.stableFileURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
