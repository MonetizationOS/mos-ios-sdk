import SwiftUI

/// One row per screen, grouped by use case, under live rows for the current mode, identity and source.
/// A wide window shows the list beside the chosen screen; a narrow one collapses to a stack.
struct HomeView: View {
    @Environment(Showcase.self) private var showcase
    @State private var showingSettings = false
    @State private var selection: ShowcaseScreen?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Now") {
                    ValueRow("Mode", showcase.modeLabel, id: "home.mode")
                    ValueRow("Identity", showcase.identity, id: "home.identity")
                    ValueRow("Last decision", lastDecision, id: "home.source")
                }
                ForEach(ShowcaseScreen.Group.allCases, id: \.self) { group in
                    Section {
                        ForEach(ShowcaseScreen.allCases.filter { $0.group == group }, id: \.self) { screen in
                            NavigationLink(value: screen) {
                                Label(screen.title, systemImage: screen.systemImage)
                            }
                            .accessibilityIdentifier("home.\(screen.rawValue)")
                        }
                    } header: {
                        Text(group.rawValue)
                    }
                }
            }
            .navigationTitle("MOS Showcase")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("home.settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsScreen().environment(showcase)
            }
        } detail: {
            if let selection {
                selection.destination
            } else {
                ContentUnavailableView("Choose a screen", systemImage: "sidebar.leading", description: Text("Each one shows an SDK call and its raw result."))
            }
        }
    }

    private var lastDecision: String {
        let source = showcase.lastSource?.label ?? "none yet"
        return showcase.isOffline ? "\(source) · offline" : source
    }
}

enum ShowcaseScreen: String, CaseIterable, Hashable {
    case gate, metered, featureSwitch, surfaceProperties
    case nativePaywall, webPaywall, redeem
    case signIn
    case offline
    case endpoints

    enum Group: String, CaseIterable {
        case basics = "Basics"
        case paywalls = "Paywalls"
        case identity = "Identity"
        case offline = "Offline"
        case apps = "Apps"
    }

    var group: Group {
        switch self {
        case .gate, .metered, .featureSwitch, .surfaceProperties: .basics
        case .nativePaywall, .webPaywall, .redeem: .paywalls
        case .signIn: .identity
        case .offline: .offline
        case .endpoints: .apps
        }
    }

    var title: String {
        switch self {
        case .gate: "Gate content"
        case .metered: "Metered access"
        case .featureSwitch: "Feature switch"
        case .surfaceProperties: "Surface properties"
        case .nativePaywall: "Native paywall"
        case .webPaywall: "Web paywall"
        case .redeem: "Redeem an offer"
        case .signIn: "Sign in and out"
        case .offline: "Offline"
        case .endpoints: "App endpoints"
        }
    }

    var systemImage: String {
        switch self {
        case .gate: "lock"
        case .metered: "gauge.with.dots.needle.33percent"
        case .featureSwitch: "switch.2"
        case .surfaceProperties: "slider.horizontal.3"
        case .nativePaywall: "rectangle.stack"
        case .webPaywall: "globe"
        case .redeem: "ticket"
        case .signIn: "person.crop.circle"
        case .offline: "wifi.slash"
        case .endpoints: "point.3.connected.trianglepath.dotted"
        }
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .gate: GateContentScreen()
        case .metered: MeteredAccessScreen()
        case .featureSwitch: FeatureSwitchScreen()
        case .surfaceProperties: SurfacePropertiesScreen()
        case .nativePaywall: NativePaywallScreen()
        case .webPaywall: WebPaywallScreen()
        case .redeem: RedeemOfferScreen()
        case .signIn: SignInScreen()
        case .offline: OfflineScreen()
        case .endpoints: AppEndpointsScreen()
        }
    }
}
