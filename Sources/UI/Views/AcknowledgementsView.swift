// AcknowledgementsView.swift
//
// The Acknowledgements page in Settings, which credits the outside software Moonlight is built
// with. A list on the left names each project and its license; selecting one shows its full
// license text and a link to its website.

import AppKit
import SwiftUI

struct AcknowledgementsView: View {
    @State private var selection: ThirdPartyAcknowledgement.ID = ThirdPartyAcknowledgements.all[0].id

    private var selectedAcknowledgement: ThirdPartyAcknowledgement {
        ThirdPartyAcknowledgements.all.first { $0.id == selection } ?? ThirdPartyAcknowledgements.all[0]
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(ThirdPartyAcknowledgements.all) { acknowledgement in
                    AcknowledgementListRow(acknowledgement: acknowledgement)
                        .tag(acknowledgement.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.bgBase)
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)

            acknowledgementDetail(selectedAcknowledgement)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bgContent)
    }

    private func acknowledgementDetail(_ acknowledgement: ThirdPartyAcknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(acknowledgement.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(acknowledgement.versionLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.textTertiary)
                    }

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(acknowledgement.homepage)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dAccent)
                    .help("Open project website")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderSoft)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(acknowledgement.files, id: \.self) { file in
                        Text(licenseText(named: file))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
            }
            .background(Color.bgContent)
        }
    }

    private func licenseText(named fileName: String) -> String {
        guard
            let url = Bundle.main.url(forResource: fileName, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Unable to load acknowledgement text for \(fileName)."
        }

        return text
    }
}

private struct AcknowledgementListRow: View {
    let acknowledgement: ThirdPartyAcknowledgement

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(acknowledgement.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(acknowledgement.license)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
