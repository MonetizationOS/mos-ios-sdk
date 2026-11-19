import SwiftUI

/// Every screen's frame: a one-sentence explainer and the demo UI, then the Last call panel.
/// On iOS 27.1 (built with its SDK) the two are a split arrangement: side by side where it is wide enough (iPhone Duo's
/// inner display), one column otherwise. The demo keeps its place either way, so a fold does not
/// rebuild it.
struct ScreenScaffold<Content: View>: View {
    let title: String
    let explainer: String
    let lastCall: LastCall?
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            #if canImport(SwiftUICore, _version: 8.0.85) // the iOS 27.1 SDK, the first with ArrangementView
            if #available(iOS 27.1, *) {
                ArrangementView {
                    ScrollView {
                        ArrangedDemo(lastCall: lastCall) { demo }.padding()
                    }
                } secondary: {
                    ScrollView { LastCallPanel(lastCall: lastCall).padding() }
                }
                .arrangementViewStyle(.split.axes(.horizontal))
            } else {
                singleColumn
            }
            #else
            singleColumn
            #endif
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var singleColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                demo
                LastCallPanel(lastCall: lastCall)
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var demo: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(explainer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("screen.explainer")
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if canImport(SwiftUICore, _version: 8.0.85)
/// The primary pane: the demo, and the Last call panel under it unless the panes sit side by side.
@available(iOS 27.1, *)
private struct ArrangedDemo<Demo: View>: View {
    let lastCall: LastCall?
    @ViewBuilder let demo: Demo
    @Environment(\.splitArrangementAxis) private var splitAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            demo
            // Tall arrangements report .vertical but, limited to horizontal splits, show one pane.
            if splitAxis != .horizontal { LastCallPanel(lastCall: lastCall) }
        }
    }
}
#endif

/// Grey stand-ins for real content.
struct PlaceholderBlock: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.gray.opacity(0.25))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

struct PlaceholderArticle: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaceholderBlock(height: 140)
            Text(title).font(.title3.bold())
            ForEach(0..<4, id: \.self) { _ in PlaceholderBlock() }
            PlaceholderBlock(width: 180)
        }
    }
}

struct LockedPlaceholder: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.title)
            Text(text).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A label and a value on one line, with an identifier the UI tests read.
struct ValueRow: View {
    let label: String
    let value: String
    let id: String

    init(_ label: String, _ value: String, id: String) {
        self.label = label
        self.value = value
        self.id = id
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
        .font(.subheadline)
    }
}
