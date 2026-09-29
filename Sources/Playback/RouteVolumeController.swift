// RouteVolumeController.swift
//
// Decides how the Mac app changes the volume of the current output device, such as AirPlay
// speakers or an external audio interface. It tries the system-level AirPlay method first and
// falls back to controlling the audio device directly through the Mac's audio system, reporting
// volume changes back to the app.

import AudioToolbox
import Combine
import CoreAudio
import Foundation

enum PlaybackVolumeMode: Equatable {
    case playerVolume
    case routeVolume
    case unavailableRouteVolume
}

protocol RouteVolumeControlling: AnyObject {
    var currentVolume: Float? { get }
    var volumePublisher: AnyPublisher<Float, Never> { get }
    var routeChangePublisher: AnyPublisher<Void, Never> { get }

    func activateRoute() -> Bool
    func activate(deviceUID: String) -> Bool
    func deactivate()
    @discardableResult func setVolume(_ volume: Float) -> Bool
}

final class HybridRouteVolumeController: RouteVolumeControlling {
    private enum ActiveController {
        case outputContext
        case coreAudio
    }

    private let outputContextController: RouteVolumeControlling
    private let coreAudioController: RouteVolumeControlling
    private var activeController: ActiveController?

    init(
        outputContextController: RouteVolumeControlling = AVOutputContextRouteVolumeController(),
        coreAudioController: RouteVolumeControlling = CoreAudioRouteVolumeController()
    ) {
        self.outputContextController = outputContextController
        self.coreAudioController = coreAudioController
    }

    var currentVolume: Float? {
        switch activeController {
        case .outputContext:
            outputContextController.currentVolume
        case .coreAudio:
            coreAudioController.currentVolume
        case nil:
            outputContextController.currentVolume ?? coreAudioController.currentVolume
        }
    }

    var volumePublisher: AnyPublisher<Float, Never> {
        Publishers.Merge(outputContextController.volumePublisher, coreAudioController.volumePublisher)
            .eraseToAnyPublisher()
    }

    var routeChangePublisher: AnyPublisher<Void, Never> {
        Publishers.Merge(outputContextController.routeChangePublisher, coreAudioController.routeChangePublisher)
            .eraseToAnyPublisher()
    }

    func activateRoute() -> Bool {
        guard outputContextController.activateRoute() else {
            if activeController == .outputContext {
                activeController = nil
            }
            return false
        }
        coreAudioController.deactivate()
        activeController = .outputContext
        return true
    }

    func activate(deviceUID: String) -> Bool {
        if outputContextController.activateRoute() {
            coreAudioController.deactivate()
            activeController = .outputContext
            return true
        }

        guard coreAudioController.activate(deviceUID: deviceUID) else {
            if activeController == .coreAudio {
                activeController = nil
            }
            return false
        }
        outputContextController.deactivate()
        activeController = .coreAudio
        return true
    }

    func deactivate() {
        outputContextController.deactivate()
        coreAudioController.deactivate()
        activeController = nil
    }

    @discardableResult func setVolume(_ volume: Float) -> Bool {
        switch activeController {
        case .outputContext:
            outputContextController.setVolume(volume)
        case .coreAudio:
            coreAudioController.setVolume(volume)
        case nil:
            false
        }
    }
}

final class CoreAudioRouteVolumeController: RouteVolumeControlling {
    private let volumeSubject = PassthroughSubject<Float, Never>()
    private var deviceID: AudioObjectID?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    var currentVolume: Float? {
        guard let deviceID else { return nil }
        return readVolume(deviceID: deviceID)
    }

    var volumePublisher: AnyPublisher<Float, Never> {
        volumeSubject.eraseToAnyPublisher()
    }

    var routeChangePublisher: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }

    func activateRoute() -> Bool {
        false
    }

    func activate(deviceUID: String) -> Bool {
        deactivate()
        RouteVolumeDiagnostics.log("CoreAudio activate requested deviceUID=\(deviceUID)")
        guard let deviceID = findDeviceID(deviceUID: deviceUID) else {
            RouteVolumeDiagnostics.log("CoreAudio activate failed: no device for UID \(deviceUID)")
            return false
        }
        guard isVolumeWritable(deviceID: deviceID) else {
            RouteVolumeDiagnostics.log("CoreAudio activate failed: deviceID \(deviceID) volume is not writable")
            return false
        }
        guard let volume = readVolume(deviceID: deviceID) else {
            RouteVolumeDiagnostics.log("CoreAudio activate failed: deviceID \(deviceID) volume is not readable")
            return false
        }

        self.deviceID = deviceID
        volumeSubject.send(volume)
        addVolumeListener(deviceID: deviceID)
        RouteVolumeDiagnostics.log("CoreAudio activate succeeded: deviceID=\(deviceID) volume=\(volume)")
        return true
    }

    func deactivate() {
        guard let deviceID else { return }
        removeVolumeListener(deviceID: deviceID)
        self.deviceID = nil
    }

    @discardableResult func setVolume(_ volume: Float) -> Bool {
        guard let deviceID else { return false }
        var clampedVolume = max(0, min(1, volume))
        var address = Self.volumeAddress
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &clampedVolume
        )

        if status == noErr {
            volumeSubject.send(clampedVolume)
            RouteVolumeDiagnostics.log("CoreAudio setVolume succeeded volume=\(clampedVolume)")
        } else {
            RouteVolumeDiagnostics.log("CoreAudio setVolume failed status=\(status)")
        }
        return status == noErr
    }

    private func findDeviceID(deviceUID: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(), count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            let name = readStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "nil"
            let uid = readDeviceUID(deviceID: deviceID) ?? "nil"
            let writable = isVolumeWritable(deviceID: deviceID)
            RouteVolumeDiagnostics.log("CoreAudio device id=\(deviceID) name=\(name) uid=\(uid) writableVirtualMainVolume=\(writable)")
        }

        return deviceIDs.first { deviceID in
            readDeviceUID(deviceID: deviceID) == deviceUID
        }
    }

    private func readDeviceUID(deviceID: AudioObjectID) -> String? {
        readStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func readStringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    private func isVolumeWritable(deviceID: AudioObjectID) -> Bool {
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr else {
            return false
        }
        return isSettable.boolValue
    }

    private func readVolume(deviceID: AudioObjectID) -> Float? {
        var volume = Float32(0)
        var address = Self.volumeAddress
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &volume
        )
        guard status == noErr else { return nil }
        return max(0, min(1, volume))
    }

    private func addVolumeListener(deviceID: AudioObjectID) {
        var address = Self.volumeAddress
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let volume = self.readVolume(deviceID: deviceID) else { return }
            self.volumeSubject.send(volume)
        }
        self.listenerBlock = listenerBlock
        AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            listenerBlock
        )
    }

    private func removeVolumeListener(deviceID: AudioObjectID) {
        guard let listenerBlock else { return }
        var address = Self.volumeAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listenerBlock)
        self.listenerBlock = nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    deinit {
        deactivate()
    }
}
