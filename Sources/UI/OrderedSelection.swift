// OrderedSelection.swift
//
// Keeps track of which items (songs, albums or playlist rows) are currently selected in a list.
// It follows the usual Mac rules: a plain click selects one item, Command-click adds or removes
// an item, and Shift-click selects everything between the last click and this one.

import Foundation

struct OrderedSelection<ID: Hashable>: Equatable {
    private(set) var ids: Set<ID> = []
    private var anchorId: ID?

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: ID) -> Bool {
        ids.contains(id)
    }

    mutating func select(_ id: ID, in orderedIds: [ID], modifiers: SelectionModifiers) {
        if modifiers.contains(.shift), let anchorId,
           let anchorIndex = orderedIds.firstIndex(of: anchorId),
           let targetIndex = orderedIds.firstIndex(of: id) {
            let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            ids = Set(orderedIds[range])
            return
        }

        if modifiers.contains(.command) {
            if ids.contains(id) {
                ids.remove(id)
            } else {
                ids.insert(id)
                anchorId = id
            }
            if ids.isEmpty {
                anchorId = nil
            }
            return
        }

        ids = [id]
        anchorId = id
    }

    mutating func replace(with ids: Set<ID>) {
        self.ids = ids
        anchorId = ids.first
    }

    mutating func retain(validIds: Set<ID>) {
        ids = ids.intersection(validIds)
        if let anchorId, !validIds.contains(anchorId) {
            self.anchorId = ids.first
        }
    }

    mutating func clear() {
        ids.removeAll()
        anchorId = nil
    }
}

struct SelectionModifiers: OptionSet {
    let rawValue: Int

    static let command = SelectionModifiers(rawValue: 1 << 0)
    static let shift = SelectionModifiers(rawValue: 1 << 1)
}
