// AirPlayRouteProviding.swift
//
// Defines what the Mac player must report about where audio is going: whether AirPlay is active
// and which output device is in use. Other parts of the app use this to show the AirPlay picker
// and to choose the right way to control volume.

import AVFoundation
import Combine

protocol AirPlayRouteProviding: AnyObject {
    var airPlayRoutePickerPlayer: AVPlayer { get }
    var externalPlaybackActive: Bool { get }
    var audioOutputDeviceUniqueID: String? { get }
    var externalPlaybackActivePublisher: AnyPublisher<Bool, Never> { get }
    var audioOutputDeviceUniqueIDPublisher: AnyPublisher<String?, Never> { get }
}
