// MetadataTagFileWriter.swift
//
// Does the low-level reading and writing of song details ("tags") and cover art inside a music
// file on the Mac. After saving, it checks that each requested change took effect and that no
// other details were accidentally altered. The editing service uses it for the actual file
// changes.

import AppKit
import Foundation
import SPFKMetadata
import SPFKMetadataC

enum MetadataTagFileWriterError: LocalizedError {
    case readFailed(URL)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let url):
            "Failed to read tags from \(url.path)"
        case .verificationFailed(let message):
            message
        }
    }
}

enum MetadataTagFileWriter {
    static func values(in url: URL, fields: [EditableTagField] = EditableTagField.allCases) throws -> [EditableTagField: String] {
        let properties = try TagProperties(url: url)
        var result: [EditableTagField: String] = [:]
        for field in fields {
            if let value = properties.tag(for: field.tagKey), !value.isEmpty {
                result[field] = value
            }
        }
        return result
    }

    static func rawProperties(in url: URL) throws -> [String: String] {
        guard let properties = TagLibBridge.getProperties(url.path) as? [String: String] else {
            throw MetadataTagFileWriterError.readFailed(url)
        }
        return properties
    }

    static func apply(_ patch: TagEditPatch, to url: URL) throws {
        guard !patch.isEmpty else { return }

        if !patch.setting.isEmpty || !patch.removing.isEmpty {
            var setting: [String: String] = [:]
            for (field, value) in patch.setting {
                setting[field.tagKey.taglibKey] = value
            }

            let removing = patch.removing.map { $0.tagKey.taglibKey }
            try TagProperties.updateTags(in: url, setting: setting, removing: removing)
        }

        switch patch.artwork {
        case .unchanged:
            break
        case .remove:
            guard TagPicture.write(nil, path: url.path) else {
                throw MetadataTagFileWriterError.verificationFailed("Artwork could not be removed")
            }
        case .replace(let imageURL):
            guard let pictureRef = TagPictureRef(
                url: imageURL,
                pictureDescription: "Front Cover",
                pictureType: "Cover (front)"
            ) else {
                throw MetadataTagFileWriterError.verificationFailed("Artwork image could not be loaded")
            }
            guard TagPicture.write(pictureRef, path: url.path) else {
                throw MetadataTagFileWriterError.verificationFailed("Artwork could not be saved")
            }
        }
    }

    static func verify(_ patch: TagEditPatch, url: URL, before: [String: String], after: [String: String]) throws {
        for (field, expectedValue) in patch.setting {
            let key = field.tagKey.taglibKey
            guard after[key] == expectedValue else {
                throw MetadataTagFileWriterError.verificationFailed("Tag \(field.title) did not verify after save")
            }
        }

        for field in patch.removing {
            let key = field.tagKey.taglibKey
            guard after[key] == nil || after[key]?.isEmpty == true else {
                throw MetadataTagFileWriterError.verificationFailed("Tag \(field.title) was not cleared")
            }
        }

        let editedKeys = Set(patch.setting.keys.map { $0.tagKey.taglibKey })
            .union(patch.removing.map { $0.tagKey.taglibKey })

        for (key, value) in before where !editedKeys.contains(key) {
            guard after[key] == value else {
                throw MetadataTagFileWriterError.verificationFailed("Unedited tag \(key) changed during save")
            }
        }

        switch patch.artwork {
        case .unchanged:
            break
        case .remove:
            if (try? TagPictureRef.parsing(url: url)) != nil {
                throw MetadataTagFileWriterError.verificationFailed("Artwork was not removed")
            }
        case .replace:
            if (try? TagPictureRef.parsing(url: url)) == nil {
                throw MetadataTagFileWriterError.verificationFailed("Artwork was not saved")
            }
        }
    }

    static func artworkImage(in url: URL) -> NSImage? {
        guard let pictureRef = try? TagPictureRef.parsing(url: url) else { return nil }
        return NSImage(cgImage: pictureRef.cgImage, size: .zero)
    }
}
