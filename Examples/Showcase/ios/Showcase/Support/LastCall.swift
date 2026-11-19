import Foundation
import MonetizationOS
import SwiftUI

/// What the bottom panel of every screen shows: the call, where its answer came from, and the raw JSON.
struct LastCall: Equatable {
    let call: String
    let source: String?
    let json: String

    static func decision(_ result: DecisionResult, call: String) -> LastCall {
        var source = result.source.label
        if let failure = result.failure { source += " · network failed: \(failure.reason.rawValue)" }
        return LastCall(call: call, source: source, json: result.decision.map { pretty($0.raw) } ?? "No decision")
    }

    static func redemption(_ result: RedemptionResult, call: String) -> LastCall {
        let json: JSONValue = switch result {
        case .redeemed(let action, let eventID, let statusCode):
            ["outcome": "redeemed", "action": action.json, "eventId": eventID.map(JSONValue.string) ?? .null, "statusCode": .number(Double(statusCode))]
        case .declined(let message, let statusCode, let eventID):
            ["outcome": "declined", "message": message.map(JSONValue.string) ?? .null, "statusCode": .number(Double(statusCode)), "eventId": eventID.map(JSONValue.string) ?? .null]
        case .failed(let failure):
            ["outcome": "failed", "failure": failure.json]
        }
        return LastCall(call: call, source: nil, json: pretty(json))
    }

    static func endpoint(_ result: EndpointResult, call: String) -> LastCall {
        switch result {
        case .response(let response):
            let headers = JSONValue.object(response.headers.mapValues(JSONValue.string))
            return LastCall(call: call, source: "HTTP \(response.status)", json: pretty(["headers": headers, "body": response.json ?? .string(response.text)]))
        case .failed(let failure):
            return LastCall(call: call, source: "failed", json: pretty(failure.json))
        }
    }

    static func text(_ call: String, _ json: JSONValue) -> LastCall {
        LastCall(call: call, source: nil, json: pretty(json))
    }

    static func pretty(_ json: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "\(json)"
    }
}

extension Action {
    var json: JSONValue {
        switch self {
        case .navigate(let url, let properties): ["type": "navigate", "url": .string(url.absoluteString), "properties": properties]
        case .custom(let type, let properties): ["type": .string(type), "properties": properties]
        case .noAction(let properties): ["type": "none", "properties": properties]
        }
    }
}

extension Failure {
    var json: JSONValue {
        ["reason": .string(reason.rawValue), "status": status.map { .number(Double($0)) } ?? .null, "message": .string(message)]
    }
}

/// The collapsible "Last call" panel at the bottom of each screen.
struct LastCallPanel: View {
    let lastCall: LastCall?
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let lastCall {
                VStack(alignment: .leading, spacing: 8) {
                    Text(lastCall.call)
                        .font(.footnote.monospaced().weight(.semibold))
                        .accessibilityIdentifier("lastCall.call")
                    if let source = lastCall.source {
                        Text("source: \(source)")
                            .font(.footnote.monospaced())
                            .accessibilityIdentifier("lastCall.source")
                    }
                    ScrollView(.horizontal) {
                        Text(lastCall.json)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("lastCall.json")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } else {
                Text("No call yet").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
        } label: {
            Text("Last call").font(.headline)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
