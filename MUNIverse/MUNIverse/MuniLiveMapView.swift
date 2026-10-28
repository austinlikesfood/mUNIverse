//
//  MuniLiveMapView.swift
//  mUNIverse
//
//  Live map of SF Muni buses, Metro trains, streetcars and cable cars,
//  powered by the 511 SF Bay Open Data "VehicleMonitoring" (SIRI) feed.
//
//  SETUP
//  1. Get a free API key at https://511.org/open-data/token
//  2. In Xcode, select your app target → Info tab → add a row:
//        Key: MUNI_511_API_KEY    Type: String    Value: <your key>
//  3. Show MuniLiveMapView() from inside a NavigationStack
//     (for example from a tile on HomeView).
//
//  RATE LIMIT
//  A 511 key allows 60 requests per hour by default, so this screen polls
//  every 90 seconds. Every copy of the app would share that one key, so
//  before shipping to real users, route these calls through your own
//  backend (it fetches once and serves all users), and point
//  MuniVehicleService at that backend instead.
//
//  Requirements: iOS 17+
//

import SwiftUI
import MapKit

// MARK: - Configuration

enum MuniConfig {
    /// Read from the app's Info.plist so the key isn't written in source code.
    static var apiKey: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MUNI_511_API_KEY") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 511's operator code for SF Muni.
    static let agency = "SF"

    /// 90 s ≈ 40 requests/hour, safely under the default 60/hour limit.
    static let refreshInterval: Duration = .seconds(90)

    /// Hide vehicles whose last GPS report is older than this.
    static let staleAfter: TimeInterval = 10 * 60

    static var sanFrancisco: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4348),
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        )
    }
}

// MARK: - Model

enum TransitMode: String, CaseIterable, Identifiable, Sendable {
    case bus
    case rail
    case cableCar

    var id: Self { self }

    private static let cableCarLines: Set<String> = ["PH", "PM", "C"]
    private static let railLines: Set<String> = ["E", "F", "J", "K", "L", "M", "N", "S", "T"]

    /// Muni Metro, streetcar and cable car lines are identified by their line code;
    /// everything else (including "KBUS"-style rail substitutes) is a bus.
    init(line: String) {
        let code = line.uppercased()
        if Self.cableCarLines.contains(code) {
            self = .cableCar
        } else if Self.railLines.contains(code) {
            self = .rail
        } else {
            self = .bus
        }
    }

    var title: String {
        switch self {
        case .bus:      "Buses"
        case .rail:     "Metro & Streetcars"
        case .cableCar: "Cable Cars"
        }
    }

    var systemImage: String {
        switch self {
        case .bus:      "bus.fill"
        case .rail:     "tram.fill"
        case .cableCar: "cablecar.fill"
        }
    }

    var color: Color {
        switch self {
        case .bus:      .red
        case .rail:     .blue
        case .cableCar: .brown
        }
    }
}

struct MuniVehicle: Identifiable, Hashable, Sendable {
    let id: String              // vehicle number
    let line: String            // e.g. "14", "N", "PH"
    let lineName: String        // e.g. "MISSION"
    let destination: String?
    let nextStop: String?
    let latitude: Double
    let longitude: Double
    let bearing: Double?        // degrees clockwise from north
    let occupancy: String?
    let recordedAt: Date?

    var mode: TransitMode { TransitMode(line: line) }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var occupancyText: String? {
        switch (occupancy ?? "").lowercased() {
        case "seatsavailable":    "Seats available"
        case "standingavailable": "Standing room"
        case "full":              "Full"
        default:                  nil
        }
    }
}

// MARK: - 511 API

enum MuniAPIError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:   "No 511 API key set."
        case .unauthorized:    "The 511 API key was rejected. Check MUNI_511_API_KEY."
        case .rateLimited:     "Hit the 511 hourly request limit. Positions will resume shortly."
        case .server(let code): "511 server error (\(code)). Retrying soon."
        case .invalidResponse: "Couldn't read the 511 response."
        }
    }
}

struct MuniVehicleService: Sendable {
    var apiKey: String = MuniConfig.apiKey
    var agency: String = MuniConfig.agency

    func fetchVehicles() async throws -> [MuniVehicle] {
        guard !apiKey.isEmpty else { throw MuniAPIError.missingAPIKey }

        var components = URLComponents(string: "https://api.511.org/transit/VehicleMonitoring")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "agency", value: agency),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw MuniAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MuniAPIError.invalidResponse }

        switch http.statusCode {
        case 200:      return try MuniVehicleParser.parse(data)
        case 401, 403: throw MuniAPIError.unauthorized
        case 429:      throw MuniAPIError.rateLimited
        default:       throw MuniAPIError.server(http.statusCode)
        }
    }
}

/// Turns 511's SIRI JSON into `MuniVehicle`s.
/// The feed has quirks this handles: a UTF-8 byte-order mark before the JSON,
/// numbers sent as strings, and fields that are sometimes missing or null.
enum MuniVehicleParser {
    static func parse(_ raw: Data, now: Date = .now) throws -> [MuniVehicle] {
        var data = raw
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data(data.dropFirst(3)) }

        let response: SiriResponse
        do {
            response = try JSONDecoder().decode(SiriResponse.self, from: data)
        } catch {
            throw MuniAPIError.invalidResponse
        }

        let activities = response.siri.serviceDelivery.vehicleMonitoringDelivery?.items
            .flatMap { $0.vehicleActivity ?? [] } ?? []

        var seen = Set<String>()
        return activities.compactMap { activity -> MuniVehicle? in
            guard
                let journey = activity.journey,
                let id = journey.vehicleRef?.value, !id.isEmpty,
                let rawLine = journey.lineRef?.value, !rawLine.isEmpty,
                let lat = journey.vehicleLocation?.latitude?.value,
                let lon = journey.vehicleLocation?.longitude?.value,
                lat != 0, lon != 0
            else { return nil }

            let recordedAt = activity.recordedAtTime.flatMap { try? Date($0, strategy: .iso8601) }
            if let recordedAt, now.timeIntervalSince(recordedAt) > MuniConfig.staleAfter { return nil }
            guard seen.insert(id).inserted else { return nil }

            // Strip an agency prefix such as "SF:14" if one is present.
            let line = rawLine.split(separator: ":").last.map(String.init) ?? rawLine

            return MuniVehicle(
                id: id,
                line: line,
                lineName: journey.publishedLineName?.value ?? line,
                destination: journey.destinationName?.value,
                nextStop: journey.monitoredCall?.stopPointName?.value,
                latitude: lat,
                longitude: lon,
                bearing: journey.bearing?.value,
                occupancy: journey.occupancy?.value,
                recordedAt: recordedAt
            )
        }
    }
}

// MARK: SIRI JSON shapes

private struct SiriResponse: Decodable {
    let siri: Siri
    enum CodingKeys: String, CodingKey { case siri = "Siri" }

    struct Siri: Decodable {
        let serviceDelivery: ServiceDelivery
        enum CodingKeys: String, CodingKey { case serviceDelivery = "ServiceDelivery" }
    }

    struct ServiceDelivery: Decodable {
        let vehicleMonitoringDelivery: OneOrMany<Delivery>?
        enum CodingKeys: String, CodingKey { case vehicleMonitoringDelivery = "VehicleMonitoringDelivery" }
    }

    struct Delivery: Decodable {
        let vehicleActivity: [Activity]?
        enum CodingKeys: String, CodingKey { case vehicleActivity = "VehicleActivity" }
    }

    struct Activity: Decodable {
        let recordedAtTime: String?
        let journey: Journey?
        enum CodingKeys: String, CodingKey {
            case recordedAtTime = "RecordedAtTime"
            case journey = "MonitoredVehicleJourney"
        }
    }

    struct Journey: Decodable {
        let lineRef: FlexibleString?
        let publishedLineName: FlexibleString?
        let destinationName: FlexibleString?
        let vehicleRef: FlexibleString?
        let bearing: FlexibleDouble?
        let occupancy: FlexibleString?
        let vehicleLocation: Location?
        let monitoredCall: Call?

        enum CodingKeys: String, CodingKey {
            case lineRef = "LineRef"
            case publishedLineName = "PublishedLineName"
            case destinationName = "DestinationName"
            case vehicleRef = "VehicleRef"
            case bearing = "Bearing"
            case occupancy = "Occupancy"
            case vehicleLocation = "VehicleLocation"
            case monitoredCall = "MonitoredCall"
        }
    }

    struct Location: Decodable {
        let latitude: FlexibleDouble?
        let longitude: FlexibleDouble?
        enum CodingKeys: String, CodingKey {
            case latitude = "Latitude"
            case longitude = "Longitude"
        }
    }

    struct Call: Decodable {
        let stopPointName: FlexibleString?
        enum CodingKeys: String, CodingKey { case stopPointName = "StopPointName" }
    }
}

/// Decodes either a single object or an array of them.
private struct OneOrMany<Element: Decodable>: Decodable {
    let items: [Element]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            items = many
        } else {
            items = [try container.decode(Element.self)]
        }
    }
}

/// Accepts a string, a number, or an array of strings; never fails.
private struct FlexibleString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string.trimmingCharacters(in: .whitespaces)
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let array = try? container.decode([String].self) {
            value = array.first
        } else {
            value = nil
        }
    }
}

/// Accepts a number or a numeric string ("37.77"); never fails.
private struct FlexibleDouble: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class MuniLiveMapModel {
    private(set) var vehicles: [MuniVehicle] = []
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var enabledModes: Set<TransitMode> = Set(TransitMode.allCases)
    var lineFilter = ""

    private let service: MuniVehicleService
    private let isSample: Bool

    /// `nonisolated` so the model can be created from any context (for example a
    /// view's default argument). It only sets `let` constants, which is safe.
    nonisolated init(service: MuniVehicleService = MuniVehicleService()) {
        self.service = service
        self.isSample = false
    }

    /// Fixed data for SwiftUI previews; never calls the network.
    init(sample: [MuniVehicle]) {
        self.service = MuniVehicleService(apiKey: "")
        self.isSample = true
        self.vehicles = sample
        self.lastUpdated = .now
    }

    var needsAPIKey: Bool { !isSample && service.apiKey.isEmpty }

    var visibleVehicles: [MuniVehicle] {
        let query = lineFilter.trimmingCharacters(in: .whitespaces).uppercased()
        return vehicles.filter { vehicle in
            enabledModes.contains(vehicle.mode)
                && (query.isEmpty || vehicle.line.uppercased() == query)
        }
    }

    func refresh() async {
        guard !isSample, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            vehicles = try await service.fetchVehicles()
            lastUpdated = .now
            errorMessage = nil
        } catch is CancellationError {
            // View went away; nothing to report.
        } catch let error as URLError where error.code == .cancelled {
            // Same as above.
        } catch {
            errorMessage = error.localizedDescription   // keep showing the last good positions
        }
    }

    /// Refreshes now, then every `MuniConfig.refreshInterval` until the task is cancelled.
    func startPolling() async {
        guard !isSample, !needsAPIKey else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: MuniConfig.refreshInterval)
        }
    }
}

// MARK: - Live Map Screen

@MainActor
struct MuniLiveMapView: View {
    @State private var model: MuniLiveMapModel
    @State private var position: MapCameraPosition = .region(MuniConfig.sanFrancisco)
    @State private var selectedID: MuniVehicle.ID?

    init(model: MuniLiveMapModel = MuniLiveMapModel()) {
        _model = State(initialValue: model)
    }

    private var selectedVehicle: MuniVehicle? {
        guard let selectedID else { return nil }
        return model.vehicles.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if model.needsAPIKey {
                MissingKeyView()
            } else {
                map
            }
        }
        .navigationTitle("Live Map")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoading || model.needsAPIKey)
                .accessibilityLabel("Refresh vehicle positions")
            }
        }
        .task { await model.startPolling() }   // stops automatically when the screen closes
    }

    private var map: some View {
        Map(position: $position) {
            ForEach(model.visibleVehicles) { vehicle in
                Annotation(vehicle.line, coordinate: vehicle.coordinate, anchor: .center) {
                    Button {
                        withAnimation(.snappy) { selectedID = vehicle.id }
                    } label: {
                        VehicleMarker(vehicle: vehicle, isSelected: vehicle.id == selectedID)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterBar(model: model)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let vehicle = selectedVehicle {
                    VehicleCard(vehicle: vehicle) {
                        withAnimation(.snappy) { selectedID = nil }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                StatusBar(
                    count: model.visibleVehicles.count,
                    lastUpdated: model.lastUpdated,
                    error: model.errorMessage
                )
            }
            .padding(12)
        }
    }
}

// MARK: - Components

private struct FilterBar: View {
    @Bindable var model: MuniLiveMapModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TransitMode.allCases) { mode in
                let isOn = model.enabledModes.contains(mode)
                Button {
                    if isOn {
                        model.enabledModes.remove(mode)
                    } else {
                        model.enabledModes.insert(mode)
                    }
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 32)
                        .foregroundStyle(isOn ? Color.white : mode.color)
                        .background(isOn ? mode.color : mode.color.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }

            TextField("Line (14, N…)", text: $model.lineFilter)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct LineBadge: View {
    let line: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Text(line)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white)
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

private struct VehicleMarker: View {
    let vehicle: MuniVehicle
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let bearing = vehicle.bearing {
                // Small arrow orbiting the badge, pointing the direction of travel.
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(vehicle.mode.color)
                    .offset(y: isSelected ? -22 : -18)
                    .rotationEffect(.degrees(bearing))
            }
            LineBadge(line: vehicle.line, color: vehicle.mode.color, size: isSelected ? 36 : 26)
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vehicle.mode.title) line \(vehicle.line), vehicle \(vehicle.id)")
    }
}

private struct VehicleCard: View {
    let vehicle: MuniVehicle
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LineBadge(line: vehicle.line, color: vehicle.mode.color, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.lineName.capitalized)
                    .font(.headline)
                if let destination = vehicle.destination {
                    Text("To \(destination)")
                        .font(.subheadline)
                }
                if let nextStop = vehicle.nextStop {
                    Label("Next: \(nextStop)", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let occupancy = vehicle.occupancyText {
                        Label(occupancy, systemImage: "person.2.fill")
                    }
                    if let recordedAt = vehicle.recordedAt {
                        Label {
                            Text("\(recordedAt, style: .relative) ago")
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                    Text("#\(vehicle.id)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StatusBar: View {
    let count: Int
    let lastUpdated: Date?
    let error: String?

    var body: some View {
        HStack(spacing: 8) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .lineLimit(2)
            } else if let lastUpdated {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("\(count) vehicles · updated \(lastUpdated, style: .relative) ago")
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Loading live positions…")
            }
            Spacer(minLength: 0)
            Text("511.org")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct MissingKeyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Add your 511 API key", systemImage: "key.fill")
        } description: {
            Text("Get a free key from 511.org, then add it in Xcode under your app target's Info tab as MUNI_511_API_KEY.")
        } actions: {
            Link("Get an API key", destination: URL(string: "https://511.org/open-data/token")!)
        }
    }
}

// MARK: - Previews

#if DEBUG
extension MuniVehicle {
    static let samples: [MuniVehicle] = [
        MuniVehicle(id: "2048", line: "N", lineName: "JUDAH", destination: "Ocean Beach",
                    nextStop: "Duboce Ave & Church St", latitude: 37.7695, longitude: -122.4295,
                    bearing: 270, occupancy: "standingAvailable", recordedAt: .now.addingTimeInterval(-25)),
        MuniVehicle(id: "8712", line: "14", lineName: "MISSION", destination: "Daly City",
                    nextStop: "Mission St & 16th St", latitude: 37.7650, longitude: -122.4194,
                    bearing: 200, occupancy: "seatsAvailable", recordedAt: .now.addingTimeInterval(-40)),
        MuniVehicle(id: "1051", line: "F", lineName: "MARKET & WHARVES", destination: "Fisherman's Wharf",
                    nextStop: "The Embarcadero & Ferry Building", latitude: 37.7955, longitude: -122.3937,
                    bearing: 330, occupancy: nil, recordedAt: .now.addingTimeInterval(-15)),
        MuniVehicle(id: "12", line: "PH", lineName: "POWELL-HYDE", destination: "Hyde & Beach",
                    nextStop: "Powell St & Jackson St", latitude: 37.7946, longitude: -122.4113,
                    bearing: 0, occupancy: "full", recordedAt: .now.addingTimeInterval(-60)),
        MuniVehicle(id: "6501", line: "38", lineName: "GEARY", destination: "Transbay Terminal",
                    nextStop: "Geary Blvd & Fillmore St", latitude: 37.7845, longitude: -122.4330,
                    bearing: 85, occupancy: "seatsAvailable", recordedAt: .now.addingTimeInterval(-30)),
        MuniVehicle(id: "2133", line: "K", lineName: "INGLESIDE", destination: "Balboa Park",
                    nextStop: "West Portal Station", latitude: 37.7406, longitude: -122.4655,
                    bearing: 160, occupancy: nil, recordedAt: .now.addingTimeInterval(-20)),
    ]
}

#Preview("Sample data") {
    NavigationStack {
        MuniLiveMapView(model: MuniLiveMapModel(sample: MuniVehicle.samples))
    }
}

#Preview("Live (needs API key)") {
    NavigationStack {
        MuniLiveMapView()
    }
}
#endif
