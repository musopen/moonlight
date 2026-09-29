// BuiltInScenes.swift
//
// Lists the animated background videos (such as rain, trees and mountains) that ship inside the
// app and can play behind the music. It also finds where each video lives in the app bundle and
// picks a default one.

import Foundation

struct BuiltInScene: Identifiable, Equatable {
    let id: String
    let title: String
    let resourceName: String
    let fileExtension: String

    var url: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
            ?? Bundle.main.url(forResource: resourceName, withExtension: fileExtension, subdirectory: "Scenes")
            ?? Bundle.main.url(forResource: resourceName, withExtension: fileExtension, subdirectory: "Resources/Scenes")
    }
}

enum BuiltInScenes {
    static let all: [BuiltInScene] = [
        BuiltInScene(id: "rain-flowers", title: "Rain Flowers", resourceName: "rain-flowers", fileExtension: "mp4"),
        BuiltInScene(id: "rain", title: "Rain", resourceName: "rain", fileExtension: "mp4"),
        BuiltInScene(id: "rain2", title: "Rain II", resourceName: "rain2", fileExtension: "mp4"),
        BuiltInScene(id: "trees", title: "Trees", resourceName: "trees", fileExtension: "mp4"),
        BuiltInScene(id: "mountains", title: "Mountains", resourceName: "mountains", fileExtension: "mp4")
    ]

    static var defaultScene: BuiltInScene? {
        all.first { $0.url != nil }
    }

    static var rainURL: URL? {
        all.first { $0.id == "rain" }?.url
    }
}
