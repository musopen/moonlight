// ScanErrorsSheet.swift
//
// A pop-up window listing the music files that could not be imported during the last library
// scan, with a Done button to close it. The list itself comes from the scan errors view.

import SwiftUI

struct ScanErrorsSheet: View {
    let errors: [ScanErrorItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Errors")
                        .font(.headline)
                    Text("\(errors.count) \(errors.count == 1 ? "file" : "files") could not be imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            ScanErrorsView(errors: errors)
        }
        .frame(minWidth: 520, minHeight: 320)
        .preferredColorScheme(.dark)
    }
}
