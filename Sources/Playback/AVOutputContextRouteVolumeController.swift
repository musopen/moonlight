// AVOutputContextRouteVolumeController.swift
//
// Controls the volume of the speaker or AirPlay device the Mac is currently playing to, rather
// than only the app's own volume. It does this through undocumented Apple system features, looked
// up by name while the app is running, and notices when the output device or its volume changes.
// It is one of the two volume methods combined in RouteVolumeController.swift.

import AVFoundation
import Combine
import Foundation
import ObjectiveC

enum AVOutputContextSPI {
    private static let sharedContext: AnyObject? = makeAudioContext()

    static var sharedAudioContext: AnyObject? {
        sharedContext
    }

    static func makeAudioContext() -> AnyObject? {
        guard let outputContextClass = NSClassFromString("AVOutputContext") else { return nil }
        let receiver = outputContextClass as AnyObject
        return callObject(receiver, selector: NSSelectorFromString("iTunesAudioContext"))
            ?? callObject(receiver, selector: NSSelectorFromString("defaultSharedOutputContext"))
    }

    static func attach(_ context: AnyObject?, to player: AVPlayer) {
        guard let context,
              player.responds(to: NSSelectorFromString("setOutputContext:")) else { return }
        sendObject(player, selector: NSSelectorFromString("setOutputContext:"), object: context)
        RouteVolumeDiagnostics.log("AVOutputContext attached to player contextID=\(outputContextID(from: context) ?? "nil") playerContextID=\(outputContextID(from: player) ?? "nil")")
    }

    static func outputContextID(from context: AnyObject?) -> String? {
        guard let context else { return nil }
        return callObject(context, selector: NSSelectorFromString("ID")) as? String
    }

    static func outputContextID(from player: AVPlayer?) -> String? {
        guard let player,
              let context = callObject(player, selector: NSSelectorFromString("outputContext")) else { return nil }
        return outputContextID(from: context)
    }

    static func attachOutputContextID(from player: AVPlayer?, to routePickerView: AnyObject) {
        guard let outputContextID = outputContextID(from: player) as NSString?,
              routePickerView.responds(to: NSSelectorFromString("setOutputContextID:")) else { return }
        sendObject(routePickerView, selector: NSSelectorFromString("setOutputContextID:"), object: outputContextID)
    }

    static func canSetVolume(_ context: AnyObject?) -> Bool {
        guard let context,
              context.responds(to: NSSelectorFromString("canSetVolume")) else { return false }
        return callBool(context, selector: NSSelectorFromString("canSetVolume"))
    }

    static func volume(_ context: AnyObject?) -> Float? {
        guard let context,
              context.responds(to: NSSelectorFromString("volume")) else { return nil }
        return max(0, min(1, callFloat(context, selector: NSSelectorFromString("volume"))))
    }

    static func setVolume(_ volume: Float, on context: AnyObject?) -> Bool {
        guard let context,
              canSetVolume(context),
              context.responds(to: NSSelectorFromString("setVolume:")) else { return false }
        sendFloat(context, selector: NSSelectorFromString("setVolume:"), value: max(0, min(1, volume)))
        return true
    }

    static func outputDevices(from context: AnyObject?) -> [AnyObject] {
        guard let context,
              context.responds(to: NSSelectorFromString("outputDevices")),
              let devices = callObject(context, selector: NSSelectorFromString("outputDevices")) else { return [] }
        return (devices as? [AnyObject]) ?? []
    }

    static func describe(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        let id = object.responds(to: NSSelectorFromString("ID"))
            ? callObject(object, selector: NSSelectorFromString("ID")) as? String
            : nil
        let deviceName = object.responds(to: NSSelectorFromString("deviceName"))
            ? callObject(object, selector: NSSelectorFromString("deviceName")) as? String
            : nil
        let plainName = object.responds(to: NSSelectorFromString("name"))
            ? callObject(object, selector: NSSelectorFromString("name")) as? String
            : nil
        let name = deviceName ?? plainName
        return "\(object) id=\(id ?? "nil") name=\(name ?? "nil") canSetVolume=\(canSetVolume(object)) volume=\(volume(object).map { "\($0)" } ?? "nil")"
    }

    private static func callObject(_ receiver: AnyObject, selector: Selector) -> AnyObject? {
        typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let implementation = methodImplementation(receiver: receiver, selector: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(receiver, selector)?.takeUnretainedValue()
    }

    private static func callBool(_ receiver: AnyObject, selector: Selector) -> Bool {
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = methodImplementation(receiver: receiver, selector: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(receiver, selector)
    }

    private static func callFloat(_ receiver: AnyObject, selector: Selector) -> Float {
        typealias Function = @convention(c) (AnyObject, Selector) -> Float
        let implementation = methodImplementation(receiver: receiver, selector: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(receiver, selector)
    }

    private static func sendObject(_ receiver: AnyObject, selector: Selector, object: AnyObject?) {
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let implementation = methodImplementation(receiver: receiver, selector: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(receiver, selector, object)
    }

    private static func sendFloat(_ receiver: AnyObject, selector: Selector, value: Float) {
        typealias Function = @convention(c) (AnyObject, Selector, Float) -> Void
        let implementation = methodImplementation(receiver: receiver, selector: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(receiver, selector, value)
    }

    private static func methodImplementation(receiver: AnyObject, selector: Selector) -> IMP {
        class_getMethodImplementation(object_getClass(receiver), selector)!
    }
}

final class AVOutputContextRouteVolumeController: RouteVolumeControlling {
    private let baseContext: AnyObject?
    private var activeTarget: AnyObject?
    private var candidateTargets: [AnyObject] = []
    private let volumeSubject = PassthroughSubject<Float, Never>()
    private let routeChangeSubject = PassthroughSubject<Void, Never>()
    private var observers: [NSObjectProtocol] = []
    private var isActive = false

    init(context: AnyObject? = AVOutputContextSPI.sharedAudioContext) {
        self.baseContext = context
        if let context {
            candidateTargets.append(context)
            candidateTargets.append(contentsOf: AVOutputContextSPI.outputDevices(from: context))
        }
        observeOutputContextChanges()
    }

    var currentVolume: Float? {
        guard isActive else { return nil }
        return AVOutputContextSPI.volume(activeTarget)
    }

    var volumePublisher: AnyPublisher<Float, Never> {
        volumeSubject.eraseToAnyPublisher()
    }

    var routeChangePublisher: AnyPublisher<Void, Never> {
        routeChangeSubject.eraseToAnyPublisher()
    }

    func activateRoute() -> Bool {
        refreshCandidates(from: baseContext)
        guard let target = candidateTargets.first(where: { AVOutputContextSPI.canSetVolume($0) }),
              let volume = AVOutputContextSPI.volume(target) else {
            isActive = false
            let candidates = candidateTargets.map(AVOutputContextSPI.describe).joined(separator: " | ")
            RouteVolumeDiagnostics.log("AVOutputContext activate failed candidates=[\(candidates)]")
            return false
        }
        activeTarget = target
        isActive = true
        volumeSubject.send(volume)
        RouteVolumeDiagnostics.log("AVOutputContext activate succeeded target=\(AVOutputContextSPI.describe(target)) volume=\(volume)")
        return true
    }

    func activate(deviceUID: String) -> Bool {
        activateRoute()
    }

    func deactivate() {
        isActive = false
        activeTarget = nil
    }

    @discardableResult func setVolume(_ volume: Float) -> Bool {
        guard AVOutputContextSPI.setVolume(volume, on: activeTarget) else {
            RouteVolumeDiagnostics.log("AVOutputContext setVolume failed")
            return false
        }
        let newVolume = AVOutputContextSPI.volume(activeTarget) ?? max(0, min(1, volume))
        volumeSubject.send(newVolume)
        RouteVolumeDiagnostics.log("AVOutputContext setVolume succeeded volume=\(newVolume)")
        return true
    }

    private func refreshCandidates(from object: AnyObject?) {
        guard let object else { return }
        addCandidate(object)
        AVOutputContextSPI.outputDevices(from: object).forEach(addCandidate)
    }

    private func addCandidate(_ object: AnyObject) {
        guard object.responds(to: NSSelectorFromString("volume")),
              object.responds(to: NSSelectorFromString("setVolume:")),
              object.responds(to: NSSelectorFromString("canSetVolume")) else { return }
        let alreadyKnown = candidateTargets.contains { $0 === object }
        if !alreadyKnown {
            candidateTargets.append(object)
            RouteVolumeDiagnostics.log("AVOutputContext candidate added \(AVOutputContextSPI.describe(object))")
        }
    }

    private func observeOutputContextChanges() {
        let notificationNames = [
            "AVOutputContextVolumeDidChangeNotification",
            "AVOutputContextCanSetVolumeDidChangeNotification",
            "AVOutputContextOutputDevicesDidChangeNotification"
        ].map { Notification.Name($0) }

        observers = notificationNames.map { name -> NSObjectProtocol in
            let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let notificationObject = notification.object as AnyObject?
                self.refreshCandidates(from: notificationObject)
                if self.isActive, let volume = AVOutputContextSPI.volume(self.activeTarget) {
                    self.volumeSubject.send(volume)
                }
                if name.rawValue != "AVOutputContextVolumeDidChangeNotification" {
                    self.routeChangeSubject.send(())
                } else if !self.isActive, notificationObject.map(AVOutputContextSPI.canSetVolume) == true {
                    self.routeChangeSubject.send(())
                }
                RouteVolumeDiagnostics.log("AVOutputContext notification \(name.rawValue) object=\(AVOutputContextSPI.describe(notificationObject)) activeTarget=\(AVOutputContextSPI.describe(self.activeTarget))")
            }
            return observer
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
