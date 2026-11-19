import Foundation
import MonetizationOS
import os

/// The Offline screen's switch. Not persisted: every launch starts online.
final class OfflineSwitch: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Fails every request like airplane mode while the switch is on, so the SDK's offline path can be
/// tried without touching the device's network. Wraps the fixture transport or the real one.
struct OfflineTransport: HTTPTransport {
    let base: any HTTPTransport
    let offline: OfflineSwitch

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if offline.isOn { throw URLError(.notConnectedToInternet) }
        return try await base.send(request)
    }
}
