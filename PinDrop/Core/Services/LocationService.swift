import CoreLocation
import MapKit
import Observation
import UIKit

enum LocationError: LocalizedError, Sendable, Equatable {
    case notAuthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            String(localized: "location.error.notAuthorized")
        case .unavailable:
            String(localized: "location.error.unavailable")
        }
    }
}

/// Privacy-first wrapper around `CLLocationManager`.
///
/// - Only `requestWhenInUseAuthorization()` is ever used (never "Always").
/// - No background tracking. Live updates run only while the map is on screen (foreground), to
///   show your own position, how long you've been there and visits to your saved places. Those
///   positions stay on the device; only the photo location and place visits are uploaded.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var lastFix: GeoPoint?
    private(set) var lastFixDate: Date?
    private(set) var isLiveUpdating = false
    /// Current speed in m/s (nil when unknown or standing still), live updates only.
    private(set) var speed: Double?
    /// Direction of travel in degrees from north (nil when unknown).
    private(set) var course: Double?
    /// Called on every fix while live updates are running.
    @ObservationIgnored var liveFixHandler: (@MainActor (GeoPoint) -> Void)?
    /// Called for fixes received while the app is in the background (or relaunched by iOS
    /// for a significant location change), to share them with friends.
    @ObservationIgnored var backgroundFixHandler: (@MainActor (GeoPoint) -> Void)?
    @ObservationIgnored private var isMonitoringSignificantChanges = false
    private static let askedAlwaysKey = "pindrop.location.askedAlways"

    private let manager = CLLocationManager()
    @ObservationIgnored private var locationContinuations: [CheckedContinuation<GeoPoint?, Never>] = []
    @ObservationIgnored private var authorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutDeadline: Date?
    @ObservationIgnored private var placeNameCache: [String: String] = [:]

    /// Average walking speed used when Apple Maps cannot compute a route (≈ 4.7 km/h).
    static let fallbackWalkingSpeed: Double = 1.3

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .other
        authorizationStatus = manager.authorizationStatus
        updateBackgroundMonitoring()
    }

    /// `true` when location is allowed even with the app closed.
    var hasAlwaysPermission: Bool {
        authorizationStatus == .authorizedAlways
    }

    /// Permission name shared with friends.
    var permissionName: String {
        switch authorizationStatus {
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "when_in_use"
        default: "denied"
        }
    }

    /// Asks to switch to "Always". iOS shows its prompt only once; afterwards the app's
    /// Settings page is opened instead.
    func requestAlwaysAuthorization() {
        let defaults = UserDefaults.standard
        if authorizationStatus == .authorizedWhenInUse, !defaults.bool(forKey: Self.askedAlwaysKey) {
            defaults.set(true, forKey: Self.askedAlwaysKey)
            manager.requestAlwaysAuthorization()
        } else {
            SystemSettings.openAppSettings()
        }
    }

    /// With "Always", significant location changes keep friends updated even when the app is
    /// closed (iOS relaunches it in the background). Low power: roughly every 500 m.
    private func updateBackgroundMonitoring() {
        if hasAlwaysPermission {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = false
            if !isMonitoringSignificantChanges {
                isMonitoringSignificantChanges = true
                manager.startMonitoringSignificantLocationChanges()
            }
        } else if isMonitoringSignificantChanges {
            isMonitoringSignificantChanges = false
            manager.stopMonitoringSignificantLocationChanges()
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    // MARK: - Authorization

    /// Requests "When In Use" authorization if it has not been determined yet.
    @discardableResult
    func requestAuthorization() async -> CLAuthorizationStatus {
        guard authorizationStatus == .notDetermined else { return authorizationStatus }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - One-shot location

    /// Returns a single, fresh location fix (or a cached one younger than `maximumAge` seconds).
    /// Returns `nil` when location access is not granted or no fix could be obtained.
    /// `timeout` caps the wait; on timeout the last known fix (if any) is returned.
    func currentLocation(maximumAge: TimeInterval = 30, timeout: TimeInterval = 12) async -> GeoPoint? {
        guard isAuthorized else { return nil }
        if let lastFix, let lastFixDate {
            let age = Date.now.timeIntervalSince(lastFixDate)
            // While live updates run, a missing new fix means you haven't moved (distance
            // filter), so the last one is still accurate.
            if age <= maximumAge || (isLiveUpdating && age <= 600) {
                return lastFix
            }
        }
        return await withCheckedContinuation { continuation in
            locationContinuations.append(continuation)
            let deadline = Date.now.addingTimeInterval(timeout)
            if locationContinuations.count == 1 {
                if !isLiveUpdating {
                    manager.requestLocation()
                }
            } else if let timeoutDeadline, timeoutDeadline <= deadline {
                return
            }
            timeoutDeadline = deadline
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resolveLocationRequests(with: nil)
            }
        }
    }

    // MARK: - Live updates (foreground only)

    func startLiveUpdates() {
        guard isAuthorized, !isLiveUpdating else { return }
        isLiveUpdating = true
        manager.distanceFilter = 5
        manager.startUpdatingLocation()
    }

    func stopLiveUpdates() {
        guard isLiveUpdating else { return }
        isLiveUpdating = false
        speed = nil
        course = nil
        manager.stopUpdatingLocation()
        manager.distanceFilter = kCLDistanceFilterNone
    }

    private func applyMotion(speed rawSpeed: Double, course rawCourse: Double) {
        speed = rawSpeed >= 0 ? rawSpeed : nil
        course = rawCourse >= 0 ? rawCourse : nil
    }

    private func resolveLocationRequests(with point: GeoPoint?) {
        if let point {
            lastFix = point
            lastFixDate = .now
            if isLiveUpdating {
                liveFixHandler?(point)
            }
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        timeoutDeadline = nil
        let result = point ?? lastFix
        let pending = locationContinuations
        locationContinuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: result)
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        guard status != .notDetermined else { return }
        let pending = authorizationContinuations
        authorizationContinuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: status)
        }
        if !isAuthorized {
            stopLiveUpdates()
            resolveLocationRequests(with: nil)
        }
        updateBackgroundMonitoring()
    }

    // MARK: - Reverse geocoding

    /// Human-readable place name for a coordinate, resolved with `CLGeocoder` in the user's locale.
    func placeName(for point: GeoPoint) async -> String? {
        let key = String(format: "%.4f,%.4f|%@", point.latitude, point.longitude, Locale.current.identifier)
        if let cached = placeNameCache[key] {
            return cached
        }
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let geocoder = CLGeocoder()
        let name: String? = await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current) { @Sendable placemarks, _ in
                continuation.resume(returning: LocationService.describe(placemarks?.first))
            }
        }
        withExtendedLifetime(geocoder) {}
        if let name {
            placeNameCache[key] = name
        }
        return name
    }

    nonisolated private static func describe(_ placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        if let area = placemark.areasOfInterest?.first, !area.isEmpty {
            return area
        }
        if let street = placemark.thoroughfare, !street.isEmpty {
            if let locality = placemark.subLocality ?? placemark.locality, !locality.isEmpty {
                return "\(street), \(locality)"
            }
            return street
        }
        if let name = placemark.name, !name.isEmpty {
            return name
        }
        return placemark.locality ?? placemark.administrativeArea
    }

    // MARK: - Walking ETA

    /// Walking travel time from the user's current position (one-shot fix) to `destination`.
    /// Uses `MKDirections` with `.walking`; falls back to a distance-based estimate when offline.
    func walkingETA(to destination: GeoPoint) async throws -> TimeInterval {
        guard isAuthorized else { throw LocationError.notAuthorized }
        guard let origin = await currentLocation(maximumAge: 20) else { throw LocationError.unavailable }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .walking
        let directions = MKDirections(request: request)

        let routedETA: TimeInterval? = await withCheckedContinuation { continuation in
            directions.calculateETA { @Sendable response, _ in
                continuation.resume(returning: response?.expectedTravelTime)
            }
        }
        withExtendedLifetime(directions) {}

        if let routedETA, routedETA > 0 {
            return routedETA
        }
        let meters = GeoClustering.haversineDistance(from: origin, to: destination)
        return meters / Self.fallbackWalkingSpeed
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let point = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let speed = location.speedAccuracy >= 0 ? location.speed : -1
        let course = location.courseAccuracy >= 0 ? location.course : -1
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyMotion(speed: speed, course: course)
            self.resolveLocationRequests(with: point)
            if UIApplication.shared.applicationState != .active {
                self.backgroundFixHandler?(point)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.resolveLocationRequests(with: nil)
        }
    }
}

/// Deep link into this app's page of the iOS Settings app (permissions, per-app language).
enum SystemSettings {
    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
