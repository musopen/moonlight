// M3UParser.swift
//
// Reads M3U playlist files, a common plain-text playlist format, so they can be imported into
// Moonlight. It pulls out each song's file location along with any listed title and length, and
// remembers which line each entry came from so import results can be explained.

import Foundation

struct M3UExtendedInfo: Hashable, Sendable {
    let duration: Int?
    let title: String
}

/// A playlist reference retained with enough source context to explain an
/// import result. `rawPath` preserves meaningful filename whitespace.
struct M3UEntry: Hashable, Identifiable, Sendable {
    let sourceURL: URL
    let lineNumber: Int
    let rawPath: String
    let resolvedURL: URL?
    let extendedInfo: M3UExtendedInfo?

    var id: String { "\(sourceURL.absoluteString)#\(lineNumber)" }
    var displayName: String { rawPath.isEmpty ? "Line \(lineNumber)" : rawPath }
}

enum M3UParserError: LocalizedError, Equatable {
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Moonlight could not read \(url.lastPathComponent)."
        }
    }
}

enum M3UParser {
    static func parse(url: URL) throws -> [M3UEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw M3UParserError.unreadable(url)
        }
        guard var content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw M3UParserError.unreadable(url)
        }
        if content.first == "\u{FEFF}" { content.removeFirst() }

        var entries: [M3UEntry] = []
        var pendingExtendedInfo: M3UExtendedInfo?
        for (offset, rawLine) in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = String(rawLine)
            let directive = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !directive.isEmpty else { continue }
            if directive.uppercased().hasPrefix("#EXTINF:") {
                pendingExtendedInfo = parseExtendedInfo(directive)
                continue
            }
            guard !directive.hasPrefix("#") else { continue }
            entries.append(M3UEntry(
                sourceURL: url,
                lineNumber: offset + 1,
                rawPath: line,
                resolvedURL: absoluteURL(for: directive),
                extendedInfo: pendingExtendedInfo
            ))
            pendingExtendedInfo = nil
        }
        return entries
    }

    private static func parseExtendedInfo(_ directive: String) -> M3UExtendedInfo {
        let value = String(directive.dropFirst("#EXTINF:".count))
        let pieces = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let duration = pieces.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return M3UExtendedInfo(duration: duration, title: pieces.count == 2 ? String(pieces[1]) : "")
    }

    private static func absoluteURL(for line: String) -> URL? {
        if let url = URL(string: line), url.isFileURL { return url.standardizedFileURL }
        guard line.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: line).standardizedFileURL
    }
}
