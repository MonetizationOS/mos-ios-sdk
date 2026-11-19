import MonetizationOS
import SwiftUI

/// Plain HTTP to an installed app's endpoints.
struct AppEndpointsScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var status: String?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "App endpoints",
            explainer: "mos.app(namespace:).call(path:) returns .response for any HTTP status or .failed when nothing came back.",
            lastCall: lastCall
        ) {
            ValueRow("Namespace", showcase.settings.namespace, id: "endpoints.namespace")
            HStack {
                Button("GET profile") { Task { await getProfile() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("endpoints.get")
                Button("POST notes") { Task { await postNote() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("endpoints.post")
            }
            if let status {
                ValueRow("Result", status, id: "endpoints.status")
            }
        }
    }

    private func getProfile() async {
        let app = showcase.mos.app(namespace: showcase.settings.namespace)
        let result = await app.call(path: "profile", method: .get)
        show(result, call: "app(namespace: \"\(app.namespace)\").call(path: \"profile\", method: .get)")
    }

    private func postNote() async {
        let app = showcase.mos.app(namespace: showcase.settings.namespace)
        let result = await app.call(path: "notes", method: .post, body: ["text": "Note 1"])
        show(result, call: "app(namespace: \"\(app.namespace)\").call(path: \"notes\", method: .post, body:)")
    }

    private func show(_ result: EndpointResult, call: String) {
        switch result {
        case .response(let response):
            // Any status is a response; the workflow decides what 4xx means.
            status = "HTTP \(response.status)\(response.isSuccess ? "" : " (not a success)")"
        case .failed(let failure):
            status = "failed: \(failure.reason.rawValue)"
        }
        lastCall = .endpoint(result, call: call)
    }
}
