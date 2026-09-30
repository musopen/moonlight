// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKMetadataBase
import SPFKMetadataC

extension AudioFormatProperties {
    /// Creates format properties by reading from an `AVAudioFile`.
    public init(audioFile: AVAudioFile) {
        let bits = audioFile.fileFormat.bitsPerChannel
        self.init(
            channelCount: audioFile.fileFormat.channelCount,
            sampleRate: audioFile.fileFormat.sampleRate,
            bitsPerChannel: bits > 0 ? Int(bits) : nil,
            bitRate: audioFile.dataRate?.int32,
            duration: audioFile.duration
        )
    }

    /// Creates format properties from the C bridge struct returned by TagLib.
    /// Invalid negative channel counts are represented as unknown (zero).
    public init(cObject: TagAudioPropertiesC) {
        self.init(
            channelCount: AVAudioChannelCount(exactly: cObject.channelCount) ?? 0,
            sampleRate: cObject.sampleRate,
            bitsPerChannel: cObject.bitsPerSample > 0 ? Int(cObject.bitsPerSample) : nil,
            bitRate: cObject.bitRate,
            duration: cObject.duration
        )
    }
}
