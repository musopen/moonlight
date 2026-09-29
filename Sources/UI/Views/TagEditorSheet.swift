// TagEditorSheet.swift
//
// The Edit Tags window for changing a song's details, such as title, artist, album, genre, year
// and track number, and its cover art. It can edit several songs at once and only changes the
// fields the user touched. Line breaks pasted into one-line fields become spaces (the comment
// field keeps them). Changes are written back into the music files, with a report of any files
// that could not be saved.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TagEditorSheet: View {
    let context: TagEditorContext

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var originals: [EditableTagField: MultiTagValue] = [:]
    @State private var textByField: [EditableTagField: String] = [:]
    @State private var touchedFields: Set<EditableTagField> = []
    @State private var artworkImage: NSImage?
    @State private var artworkEdit: ArtworkEdit = .unchanged
    @State private var isArtworkDropTargeted = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var results: [TagEditResult] = []

    private let fields = EditableTagField.commonFields

    private var changedPatch: TagEditPatch {
        var patch = TagEditPatch()
        patch.artwork = artworkEdit

        for field in touchedFields {
            let typed = textByField[field]?.cleanedText(keepingLineBreaks: field == .comment)
            let normalized = MetadataExtractor.normalizedTagValue(typed)
            if case .same(let originalValue) = originals[field],
               normalized == MetadataExtractor.normalizedTagValue(originalValue) {
                continue
            }

            if let normalized {
                patch.setting[field] = normalized
            } else {
                patch.removing.insert(field)
            }
        }

        return patch
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading {
                ProgressView()
                    .frame(width: 860, height: 570)
            } else {
                HStack(alignment: .top, spacing: 34) {
                    leftRail
                        .frame(width: 230, alignment: .top)

                    formContent
                        .frame(width: 548, alignment: .topLeading)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 22)
                .frame(width: 860, height: 570, alignment: .top)
            }

            footer
        }
        .background(Color.bgContent)
        .task { await loadValues() }
    }

    private var header: some View {
        ZStack {
            Text(displayTitle)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .tracking(0.1)
            .lineLimit(1)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color.bgContent)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderSoft.opacity(0.7)).frame(height: 0.5)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

            Button(saveButtonTitle) {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading || isSaving || changedPatch.isEmpty)
        }
        .padding(.horizontal, 32)
        .frame(height: 56)
        .background(Color.bgChrome.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.borderSoft).frame(height: 0.5)
        }
    }

    private var saveButtonTitle: String {
        if isSaving { return "Saving..." }
        let count = context.tracks.count
        return count == 1 ? "Apply" : "Apply to \(count.formatted()) tracks"
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            fullWidthField(.title)
            fullWidthField(.artist)
            fullWidthField(.album)
            fullWidthField(.albumArtist)
            fullWidthField(.composer)
            fullWidthField(.genre)
            yearDiscTrackRow
            fullWidthField(.comment)
            compilationRow
            resultSummary
        }
    }

    private func fullWidthField(_ field: EditableTagField) -> some View {
        fieldStack(label: field.title) {
            editorField(field)
        }
    }

    private var yearDiscTrackRow: some View {
        HStack(alignment: .top, spacing: 16) {
            compactField(.date, label: "Year")
            compactField(.discNumber, label: "Disc")
            compactField(.trackNumber, label: "Track")
        }
    }

    private var compilationRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: compilationBinding) {
                Text("Compilation")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            .toggleStyle(.checkbox)

            Spacer()
        }
        .frame(height: 20)
    }

    private func compactField(_ field: EditableTagField, label: String) -> some View {
        fieldStack(label: label) {
            editorField(field)
        }
        .frame(maxWidth: .infinity)
    }

    private func fieldStack<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Color.textTertiary)
            content()
        }
    }

    private func editorField(_ field: EditableTagField) -> some View {
        TextField("", text: binding(for: field), prompt: Text(originals[field]?.isMixed == true ? "Mixed" : ""))
            .textFieldStyle(.plain)
            .font(.system(size: 14.5))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderMedium, lineWidth: 0.7))
            )
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            artworkEditor

            Spacer(minLength: 0)
        }
    }

    private var artworkEditor: some View {
        VStack(alignment: .center, spacing: 14) {
            artworkPreview

            Button("Replace artwork") { chooseArtwork() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.045))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderMedium, lineWidth: 0.7))
                )

            HStack(spacing: 8) {
                Text(artworkStatus)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button("Remove") {
                    artworkImage = nil
                    artworkEdit = .remove
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .disabled(artworkImage == nil && artworkEdit == .unchanged)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var artworkPreview: some View {
        ZStack {
            ZStack {
                if let artworkImage {
                    Image(nsImage: artworkImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 214, height: 214)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isArtworkDropTargeted ? Color.accentColor : Color.borderMedium, lineWidth: isArtworkDropTargeted ? 2 : 0.7)
            )
            .overlay {
                if isArtworkDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.16))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onDrop(
            of: [UTType.image.identifier, UTType.fileURL.identifier],
            isTargeted: $isArtworkDropTargeted,
            perform: handleArtworkDrop
        )
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.11),
                    Color.white.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 2)
                .frame(width: 136, height: 136)

            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 2)
                .frame(width: 66, height: 66)

            Circle()
                .fill(Color.textQuaternary)
                .frame(width: 10, height: 10)
        }
    }

    private var artworkStatus: String {
        if isArtworkDropTargeted {
            return "Drop image to replace artwork"
        }

        switch artworkEdit {
        case .unchanged:
            return artworkImage == nil ? "No embedded artwork" : "Embedded artwork"
        case .replace(let url):
            return "Will use \(url.lastPathComponent)"
        case .remove:
            return "Will remove artwork"
        }
    }

    private var displayTitle: String {
        switch context.title {
        case "Edit Tags":
            "Edit Metadata"
        case "Edit Album Tags":
            "Edit Album Metadata"
        case "Edit Selected Tags", "Edit Selected Album Tags":
            "Edit Selected Metadata"
        default:
            context.title.replacingOccurrences(of: "Tags", with: "Metadata")
        }
    }

    @ViewBuilder
    private var resultSummary: some View {
        if !results.isEmpty {
            let failures = results.compactMap { result -> String? in
                if case .failed(let message) = result.status {
                    return "\(URL(string: result.fileURL)?.lastPathComponent ?? result.fileURL): \(message)"
                }
                return nil
            }
            if failures.isEmpty {
                Text("Saved \(results.count.formatted()) \(results.count == 1 ? "file" : "files").")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Some files could not be saved.")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    ForEach(failures, id: \.self) { failure in
                        Text(failure)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var compilationBinding: Binding<Bool> {
        Binding {
            MetadataExtractor.normalizedTagValue(textByField[.compilation]) == "1"
        } set: { isOn in
            textByField[.compilation] = isOn ? "1" : ""
            touchedFields.insert(.compilation)
        }
    }

    private func binding(for field: EditableTagField) -> Binding<String> {
        Binding {
            textByField[field, default: ""]
        } set: { value in
            textByField[field] = value
            touchedFields.insert(field)
        }
    }

    private func loadValues() async {
        async let loadedValues = appState.metadataEditingService.loadValues(for: context.tracks, fields: fields)
        async let loadedArtwork = appState.metadataEditingService.loadArtwork(for: context.tracks.first)

        let values = await loadedValues
        originals = values
        textByField = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field, values[field]?.displayValue ?? "")
        })
        artworkImage = await loadedArtwork
        isLoading = false
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose artwork to embed in the selected audio files."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            artworkImage = NSImage(contentsOf: url)
            artworkEdit = .replace(url)
        }
    }

    private func handleArtworkDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            loadDroppedArtworkFile(from: provider)
            return true
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            loadDroppedArtworkData(from: provider)
            return true
        }

        return false
    }

    private func loadDroppedArtworkFile(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }

            guard let url, let image = NSImage(contentsOf: url) else { return }

            Task { @MainActor in
                artworkImage = image
                artworkEdit = .replace(url)
            }
        }
    }

    private func loadDroppedArtworkData(from provider: NSItemProvider) {
        let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) && type != .image
        } ?? UTType.image.identifier

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data, let image = NSImage(data: data) else { return }

            let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoonlightDroppedArtwork-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)

            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }

            Task { @MainActor in
                artworkImage = image
                artworkEdit = .replace(url)
            }
        }
    }

    private func save() async {
        let patch = changedPatch
        guard !patch.isEmpty else { return }

        isSaving = true
        results = await appState.saveTagEdits(patch, for: context.tracks)
        isSaving = false

        if results.allSatisfy({
            if case .saved = $0.status { return true }
            return false
        }) {
            dismiss()
        }
    }
}
