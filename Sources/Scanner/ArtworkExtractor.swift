// ArtworkExtractor.swift
//
// Finds album cover pictures stored as image files beside the music, such as "cover.jpg" or
// "folder.png", including in disc subfolders and "artwork" or "scans" folders. It also makes
// smaller copies (thumbnails) of cover images for quick display in the library.

import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FolderArtwork {
    let data: Data
    let url: URL

    var fileSize: Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    var modifiedAt: Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

enum ArtworkExtractor {
    private static let folderImageNames = [
        "cover", "folder", "front", "artwork", "album", "thumb"
    ]
    private static let folderImageExtensions = ["jpg", "jpeg", "png", "webp"]
    private static let artworkSubfolders = ["art", "artwork", "covers", "scans", "booklet"]

    static func folderImage(for trackURL: URL) -> Data? {
        folderArtwork(for: trackURL)?.data
    }

    static func folderArtwork(for trackURL: URL) -> FolderArtwork? {
        for dir in artworkSearchDirectories(for: trackURL) {
            if let artwork = firstArtwork(in: dir) { return artwork }
        }
        return nil
    }

    private static func artworkSearchDirectories(for trackURL: URL) -> [URL] {
        let trackDir = trackURL.deletingLastPathComponent()
        var dirs = [trackDir]

        let parent = trackDir.deletingLastPathComponent()
        if isDiscFolder(trackDir.lastPathComponent) {
            dirs.append(parent)
        }

        let baseDirs = dirs
        for base in baseDirs {
            dirs.append(contentsOf: artworkSubdirectories(in: base))
        }

        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func firstArtwork(in directory: URL) -> FolderArtwork? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for candidate in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard isFolderArtworkCandidate(candidate),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: candidate) else { continue }
            return FolderArtwork(data: data, url: candidate)
        }

        return nil
    }

    private static func artworkSubdirectories(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { artworkSubfolders.contains($0.lastPathComponent.lowercased()) }
            .filter {
                guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
                return values.isDirectory == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isFolderArtworkCandidate(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        return folderImageNames.contains(name) && folderImageExtensions.contains(ext)
    }

    private static func isDiscFolder(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("cd") || value.hasPrefix("disc") || value.hasPrefix("disk") else {
            return false
        }
        return value.contains(where: { $0.isNumber })
    }

    static func thumbnail(
        from data: Data,
        size: CGFloat,
        compressionQuality: CGFloat = 0.80
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(size),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? encodedData as Data : nil
    }
}
