//
//  HomeView.swift
//
//  Home screen with four tappable rectangular tiles in a 2×2 grid.
//  Each tile navigates to its own destination via NavigationStack.
//
//  Requirements: iOS 17+, Swift 5.9+ (SwiftUI Grid, sensoryFeedback, #Preview)
//

import SwiftUI

// MARK: - Model

/// The four areas on the home screen. Add or rename cases here;
/// the grid layout below expects exactly four.
enum HomeSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case updates
    case favorites
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .updates:  "Updates"
        case .favorites: "Favorites"
        case .settings:  "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "Overview & metrics"
        case .updates:  "Line Updates"
        case .favorites:     "Most Used Lines"
        case .settings:  "Account & preferences"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "chart.bar.xaxis"
        case .updates:  "bubble.left.and.bubble.right.fill"
        case .favorites:     "checklist"
        case .settings:  "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard:.blue
        case .updates:.green
        case .favorites:.orange
        case .settings:.purple
        }
    }
}

// MARK: - Home Screen

struct HomeView: View {
    @State private var path: [HomeSection] = []

    var body: some View {
        NavigationStack(path: $path) {
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    tile(for: .dashboard)
                    tile(for: .updates)
                }
                GridRow {
                    tile(for: .favorites)
                    tile(for: .settings)
                }
            }
            .padding(16)
            .navigationTitle("Home")
            .navigationDestination(for: HomeSection.self) { section in
                SectionDetailView(section: section)
            }
        }
        // Light haptic tap whenever a tile pushes a new screen.
        .sensoryFeedback(.impact(weight: .light), trigger: path)
    }

    private func tile(for section: HomeSection) -> some View {
        NavigationLink(value: section) {
            HomeTile(section: section)
        }
        .buttonStyle(TilePressStyle())
    }
}
// MARK: - Tile

/// A single rectangular, tappable area.
struct HomeTile: View {
    let section: HomeSection

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: section.systemImage)
                .font(.title)

            Spacer(minLength: 0)

            Text(section.title)
                .font(.title3.bold())

            Text(section.subtitle)
                .font(.subheadline)
                .opacity(0.85)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(section.tint.gradient, in: shape)
        .contentShape(shape)                 // whole rectangle is tappable
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(section.title)")
    }
}

// MARK: - Press Feedback

/// Slight scale-down while the finger is on a tile.
struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Destination (placeholder)

/// Replace with your real feature screens, e.g. switch on `section`
/// and return DashboardView(), MessagesView(), etc.
struct SectionDetailView: View {
    let section: HomeSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.systemImage,
            description: Text("\(section.subtitle) goes here.")
        )
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - App Entry (use if this is a new project)
//
// @main
// struct MyApp: App {
//     var body: some Scene {
//         WindowGroup {
//             HomeView()
//         }
//     }
// }

// MARK: - Preview

#Preview {
    HomeView()
}
