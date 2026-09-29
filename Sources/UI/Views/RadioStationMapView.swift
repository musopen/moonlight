// RadioStationMapView.swift
//
// The world map on the Live Radio page, with a pin for each popular station. The user can drag
// to move around, zoom with buttons or a double-click, and click a pin to start playing that
// station; the station currently playing is highlighted.

import AppKit
import MapKit
import SwiftUI

struct RadioStationMapView: View {
    let stations: [RadioStation]
    let currentStationUUID: String?
    let onPlay: (RadioStation) -> Void

    @State private var zoomCommand = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RadioMapRepresentable(
                stations: stations,
                currentStationUUID: currentStationUUID,
                zoomCommand: zoomCommand,
                onPlay: onPlay
            )

            VStack(spacing: 4) {
                mapButton(symbol: "plus") { zoomCommand += 1 }
                mapButton(symbol: "minus") { zoomCommand -= 1 }
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color.borderSoft, lineWidth: 0.5)
        }
    }

    private func mapButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AppTheme.current.font(.icon, size: 12, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 26, height: 26)
                .background(Color.bgChrome.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.borderMedium.opacity(0.35), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct RadioMapRepresentable: NSViewRepresentable {
    let stations: [RadioStation]
    let currentStationUUID: String?
    let zoomCommand: Int
    let onPlay: (RadioStation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlay: onPlay)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = RadioMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsZoomControls = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = true
        let doubleClickRecognizer = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.zoomAtDoubleClick(_:))
        )
        doubleClickRecognizer.numberOfClicksRequired = 2
        mapView.addGestureRecognizer(doubleClickRecognizer)
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 18, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 150, longitudeDelta: 350)
            ),
            animated: false
        )
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onPlay = onPlay
        context.coordinator.sync(
            stations: stations,
            currentStationUUID: currentStationUUID,
            in: mapView
        )

        let difference = zoomCommand - context.coordinator.lastZoomCommand
        if difference != 0 {
            var region = mapView.region
            let factor = pow(0.66, Double(difference))
            region.span.latitudeDelta = min(170, max(1.2, region.span.latitudeDelta * factor))
            region.span.longitudeDelta = min(360, max(1.2, region.span.longitudeDelta * factor))
            mapView.setRegion(region, animated: true)
            context.coordinator.lastZoomCommand = zoomCommand
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onPlay: (RadioStation) -> Void
        var lastZoomCommand = 0
        private var annotationsByUUID: [String: RadioStationAnnotation] = [:]
        private var currentStationUUID: String?

        init(onPlay: @escaping (RadioStation) -> Void) {
            self.onPlay = onPlay
        }

        @objc func zoomAtDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended,
                  let mapView = recognizer.view as? MKMapView else { return }

            let clickedPoint = recognizer.location(in: mapView)
            var region = mapView.region
            region.center = mapView.convert(clickedPoint, toCoordinateFrom: mapView)
            region.span.latitudeDelta = max(1.2, region.span.latitudeDelta * 0.5)
            region.span.longitudeDelta = max(1.2, region.span.longitudeDelta * 0.5)
            mapView.setRegion(region, animated: true)
        }

        func sync(
            stations: [RadioStation],
            currentStationUUID: String?,
            in mapView: MKMapView
        ) {
            let incomingIDs = Set(stations.map(\.stationUUID))
            let currentIDs = Set(annotationsByUUID.keys)
            if incomingIDs != currentIDs {
                mapView.removeAnnotations(Array(annotationsByUUID.values))
                annotationsByUUID = Dictionary(uniqueKeysWithValues: stations.compactMap { station in
                    guard let latitude = station.latitude, let longitude = station.longitude else { return nil }
                    let annotation = RadioStationAnnotation(
                        station: station,
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    )
                    return (station.stationUUID, annotation)
                })
                mapView.addAnnotations(Array(annotationsByUUID.values))
            }

            guard self.currentStationUUID != currentStationUUID else { return }
            self.currentStationUUID = currentStationUUID
            for annotation in annotationsByUUID.values {
                updateAppearance(of: mapView.view(for: annotation), stationUUID: annotation.station.stationUUID)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let stationAnnotation = annotation as? RadioStationAnnotation else { return nil }
            let identifier = "radio-station"
            let marker = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            marker.annotation = annotation
            marker.canShowCallout = true
            marker.glyphImage = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
            updateAppearance(of: marker, stationUUID: stationAnnotation.station.stationUUID)
            return marker
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let station = (view.annotation as? RadioStationAnnotation)?.station else { return }
            onPlay(station)
            mapView.deselectAnnotation(view.annotation, animated: true)
        }

        private func updateAppearance(of view: MKAnnotationView?, stationUUID: String) {
            guard let marker = view as? MKMarkerAnnotationView else { return }
            marker.markerTintColor = stationUUID == currentStationUUID
                ? .white
                : NSColor(Color.dAccent)
            marker.glyphTintColor = stationUUID == currentStationUUID
                ? NSColor(Color.dAccentStrong)
                : .white
        }
    }
}

private final class RadioMapView: MKMapView {
    override func scrollWheel(with event: NSEvent) {
        // Keep two-finger and mouse-wheel scrolling available to the enclosing
        // radio page without letting it pan or zoom the map itself.
        nextResponder?.scrollWheel(with: event)
    }
}

private final class RadioStationAnnotation: NSObject, MKAnnotation {
    let station: RadioStation
    dynamic var coordinate: CLLocationCoordinate2D

    var title: String? { station.name }
    var subtitle: String? { station.country ?? station.countryCode }

    init(station: RadioStation, coordinate: CLLocationCoordinate2D) {
        self.station = station
        self.coordinate = coordinate
    }
}
