import CoreLocation
import MapKit

/// Guided mode: walking route to a destination, turned into a goal bearing for the gap planner and
/// spoken turn instructions. Obstacles always win; the planner only leans toward the route when the
/// path ahead is clear.
///
/// Uses MapKit walking directions (no API keys). The bearing comes from ARKit running with
/// `.gravityAndHeading` alignment, where the body yaw is already a true-north heading.
/// Use from the main thread.
final class GuidedNavigator: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case searching(String)
        case navigating(String)
        case arrived(String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .searching, .navigating: true
            default: false
            }
        }
    }

    struct Waypoint {
        let coordinate: CLLocationCoordinate2D
        let stepIndex: Int
    }

    /// A search result the user can pick.
    struct Place: Identifiable {
        let id = UUID()
        let item: MKMapItem
        let name: String
        let detail: String
        /// Meters from the user, if their location is known.
        let distance: Double?

        /// What VoiceOver and the voice say for this result.
        var spoken: String {
            let place = detail.isEmpty ? name : "\(name), \(detail)"
            guard let distance else { return place }
            return "\(place), \(GuidedNavigator.spokenDistance(distance)) away"
        }
    }

    /// Live route progress for the home screen and the camera view.
    struct Progress: Equatable {
        var nextInstruction: String
        var distanceToNextTurn: Double?
        var remaining: Double?
        /// Bearing to the next waypoint relative to the way the user faces, degrees (negative is left).
        var relativeBearing: Double?
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    /// Speak a dynamic sentence (tier .guided) or a bundled phrase id (tier .status).
    var onSpeakText: ((String) -> Void)?
    var onSpeakPhrase: ((String) -> Void)?
    var onProgress: ((Progress?) -> Void)?
    private(set) var progress: Progress? {
        didSet { if progress != oldValue { onProgress?(progress) } }
    }

    private(set) var waypoints: [Waypoint] = []
    private(set) var waypointIndex = 0
    private(set) var location: CLLocation?
    private(set) var bodyHeadingDegrees: Double?

    private let manager = CLLocationManager()
    private var steps: [MKRoute.Step] = []
    private var announcedStep = -1
    private var destinationName = ""
    private var destinationQuery = ""
    private var destination: CLLocationCoordinate2D?
    private var destinationItem: MKMapItem?
    private var lastReroute = Date.distantPast
    private var routeTask: Task<Void, Never>?

    private let waypointSpacing = 6.0
    private let arriveRadius = 8.0
    private let advanceRadius = 6.0
    private let announceRadius = 12.0
    private let offRouteDistance = 40.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
    }

    func start(query: String) {
        stop()
        destinationQuery = query
        state = .searching(query)
        beginLocationUpdates()
        routeTask = Task { @MainActor [weak self] in
            await self?.route(to: query)
        }
    }

    /// Start a route to a place the user picked from `search`.
    func start(place: Place) {
        stop()
        destinationQuery = place.name
        state = .searching(place.name)
        beginLocationUpdates()
        routeTask = Task { @MainActor [weak self] in
            await self?.route(to: place.item, query: place.name)
        }
    }

    /// Places matching `query`, nearest first when the location is known.
    @MainActor
    func search(_ query: String) async throws -> [Place] {
        beginLocationUpdates()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let location {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        let places = response.mapItems.prefix(8).map { item -> Place in
            let coordinate = item.placemark.coordinate
            let meters = location.map { self.distance($0, coordinate) }
            let detail = [item.placemark.thoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: ", ")
            return Place(item: item, name: item.name ?? query, detail: detail, distance: meters)
        }
        return places.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }.prefix(5).map { $0 }
    }

    private func beginLocationUpdates() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        routeTask?.cancel()
        routeTask = nil
        manager.stopUpdatingLocation()
        waypoints = []
        steps = []
        waypointIndex = 0
        announcedStep = -1
        destination = nil
        destinationItem = nil
        progress = nil
        state = .idle
    }

    /// From each perception frame: walking direction in radians, clockwise from true north.
    func updateBodyYaw(_ yaw: Float?) {
        bodyHeadingDegrees = yaw.map { Self.normalize360(Double($0) * 180 / .pi) }
    }

    /// Where the route goes relative to the way the user faces, in radians (negative is left).
    var relativeGoalHeading: Float? {
        guard case .navigating = state,
              let location, let heading = bodyHeadingDegrees,
              waypointIndex < waypoints.count else { return nil }
        let bearing = Self.bearing(from: location.coordinate, to: waypoints[waypointIndex].coordinate)
        return Float(Self.normalize180(bearing - heading) * .pi / 180)
    }

    var distanceToDestination: Double? {
        guard let location, let destination else { return nil }
        return location.distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
    }

    // MARK: - Routing

    @MainActor
    private func route(to query: String) async {
        do {
            guard let place = try await search(query).first else {
                state = .failed("No place found for \(query)")
                onSpeakText?("I couldn't find \(query).")
                return
            }
            await route(to: place.item, query: query)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            onSpeakText?("I couldn't search for \(query).")
        }
    }

    @MainActor
    private func route(to item: MKMapItem, query: String) async {
        do {
            let directions = MKDirections.Request()
            directions.source = MKMapItem.forCurrentLocation()
            directions.destination = item
            directions.transportType = .walking
            let response = try await MKDirections(request: directions).calculate()
            guard !Task.isCancelled, let route = response.routes.first else {
                if !Task.isCancelled {
                    state = .failed("No walking route")
                    onSpeakText?("I couldn't find a walking route.")
                }
                return
            }

            destinationName = item.name ?? query
            destinationItem = item
            destination = item.placemark.coordinate
            steps = route.steps
            waypoints = Self.buildWaypoints(steps: route.steps, spacing: waypointSpacing)
            waypointIndex = 0
            announcedStep = -1
            state = .navigating(destinationName)
            let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
            onSpeakText?("Starting route to \(destinationName). \(Self.spokenDistance(route.distance)), about \(minutes) minutes walking.")
            if let location { advance(from: location) }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            onSpeakText?("Navigation error.")
        }
    }

    static func buildWaypoints(steps: [MKRoute.Step], spacing: Double) -> [Waypoint] {
        var result: [Waypoint] = []
        for (index, step) in steps.enumerated() {
            let polyline = step.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            guard let first = coordinates.first else { continue }
            result.append(Waypoint(coordinate: first, stepIndex: index))
            for (a, b) in zip(coordinates, coordinates.dropFirst()) {
                let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                let segments = max(1, Int(ceil(distance / spacing)))
                for s in 1...segments {
                    let t = Double(s) / Double(segments)
                    let c = CLLocationCoordinate2D(
                        latitude: a.latitude + (b.latitude - a.latitude) * t,
                        longitude: a.longitude + (b.longitude - a.longitude) * t
                    )
                    result.append(Waypoint(coordinate: c, stepIndex: index))
                }
            }
        }
        return result
    }

    // MARK: - Progress

    private func advance(from location: CLLocation) {
        guard case .navigating = state else { return }

        if let remaining = distanceToDestination, remaining < arriveRadius {
            state = .arrived(destinationName)
            onSpeakPhrase?("arrived")
            manager.stopUpdatingLocation()
            return
        }

        // Skip every waypoint already within reach, and any the user has walked past.
        while waypointIndex < waypoints.count - 1 {
            let here = distance(location, waypoints[waypointIndex].coordinate)
            let next = distance(location, waypoints[waypointIndex + 1].coordinate)
            if here < advanceRadius || next < here {
                waypointIndex += 1
            } else {
                break
            }
        }

        // Announce a maneuver as the user nears the start of its step.
        if waypointIndex < waypoints.count {
            let stepIndex = waypoints[waypointIndex].stepIndex
            if stepIndex > announcedStep, stepIndex < steps.count {
                let stepStart = waypoints.first { $0.stepIndex == stepIndex }?.coordinate
                let near = stepStart.map { distance(location, $0) < announceRadius } ?? true
                if near || stepIndex == 0 {
                    announcedStep = stepIndex
                    let instruction = steps[stepIndex].instructions
                    if !instruction.isEmpty { onSpeakText?(instruction) }
                }
            }
        }

        updateProgress(from: location)

        // Far from the route: ask for a new one, at most every 30 seconds.
        let nearest = waypoints[waypointIndex...].prefix(20).map { distance(location, $0.coordinate) }.min() ?? 0
        if nearest > offRouteDistance, Date().timeIntervalSince(lastReroute) > 30 {
            lastReroute = Date()
            onSpeakPhrase?("recalculating")
            let query = destinationQuery
            let item = destinationItem
            routeTask?.cancel()
            routeTask = Task { @MainActor [weak self] in
                if let item {
                    await self?.route(to: item, query: query)
                } else {
                    await self?.route(to: query)
                }
            }
        }
    }

    private func updateProgress(from location: CLLocation) {
        guard waypointIndex < waypoints.count else { return }
        let currentStep = waypoints[waypointIndex].stepIndex
        let nextStep = currentStep + 1
        var next = Progress(nextInstruction: "Arrive at \(destinationName)")
        if nextStep < steps.count, !steps[nextStep].instructions.isEmpty {
            next.nextInstruction = steps[nextStep].instructions
            if let turn = waypoints[waypointIndex...].first(where: { $0.stepIndex == nextStep }) {
                next.distanceToNextTurn = distance(location, turn.coordinate)
            }
        } else {
            next.distanceToNextTurn = distanceToDestination
        }
        next.remaining = distanceToDestination
        if let heading = bodyHeadingDegrees {
            let bearing = Self.bearing(from: location.coordinate, to: waypoints[waypointIndex].coordinate)
            next.relativeBearing = Self.normalize180(bearing - heading)
        }
        progress = next
    }

    /// "350 meters", "1.2 kilometers".
    static func spokenDistance(_ meters: Double) -> String {
        if meters < 1000 {
            let rounded = meters < 100 ? Int((meters / 5).rounded()) * 5 : Int((meters / 10).rounded()) * 10
            return "\(rounded) meters"
        }
        return String(format: "%.1f kilometers", meters / 1000)
    }

    private func distance(_ location: CLLocation, _ coordinate: CLLocationCoordinate2D) -> Double {
        location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
        location = latest
        advance(from: latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if case .navigating = state { return }
        state = .failed(error.localizedDescription)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard state.isActive else { return }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            state = .failed("Location permission denied")
            onSpeakText?("Location access is off. Turn it on in Settings to navigate.")
        default:
            break
        }
    }

    // MARK: - Math

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize360(atan2(y, x) * 180 / .pi)
    }

    static func normalize360(_ degrees: Double) -> Double {
        let a = degrees.truncatingRemainder(dividingBy: 360)
        return a < 0 ? a + 360 : a
    }

    static func normalize180(_ degrees: Double) -> Double {
        let a = normalize360(degrees)
        return a > 180 ? a - 360 : a
    }
}
