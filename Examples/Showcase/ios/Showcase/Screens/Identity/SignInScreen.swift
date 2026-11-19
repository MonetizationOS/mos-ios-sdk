import MonetizationOS
import SwiftUI

/// Hand the SDK a signed-in reader's JWT and back, and see the anonymous reader linked on the next decision.
struct SignInScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var pastedJwt = ""
    @State private var anonymousBefore: String?
    @State private var identifyResult: IdentifyResult?
    @State private var decision: DecisionResult?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Sign in and out",
            explainer: "identify(userJWT:) switches the SDK to a signed-in reader; the next decision carries previousAnonymousIdentifier so the workflow can link the two. identify(userJWT: nil) signs out.",
            lastCall: lastCall
        ) {
            ValueRow("Anonymous id", anonymousBefore ?? "none yet", id: "signIn.anonymousId")
            if showcase.settings.mode == .live {
                TextField("Paste a JWT from your org's JWT integration", text: $pastedJwt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            HStack {
                Button("Sign in") { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("signIn.signIn")
                Button("Sign out") { Task { await signOut() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("signIn.signOut")
            }
            if let identifyResult {
                let kind = { (kind: IdentityKind?) in kind?.rawValue ?? "none" }
                ValueRow("IdentifyResult", "\(kind(identifyResult.previous)) → \(kind(identifyResult.current))", id: "signIn.identify")
                ValueRow("changed", "\(identifyResult.changed)", id: "signIn.changed")
                ValueRow("linkPending", "\(identifyResult.linkPending)", id: "signIn.linkPending")
            }
            if let identity = decision?.decision?.identity {
                ValueRow("Next decision is for", "\(identity.isAuthenticated ? "jwt" : "anonymous"): \(identity.identifier ?? "?")", id: "signIn.decisionIdentity")
                ValueRow("Carried previousAnonymousIdentifier", "\(decision?.linkedAnonymousIdentifier ?? false)", id: "signIn.linked")
            }
        }
        .task { await prepare() }
    }

    /// Only an anonymous reader the server has seen can be linked, so decide once if there is none yet.
    private func prepare() async {
        if await showcase.mos.anonymousIdentifier == nil {
            let result = await showcase.mos.decide(resource: Resource(id: "article/1"))
            showcase.didDecide(result)
        }
        anonymousBefore = await showcase.mos.anonymousIdentifier
    }

    private func signIn() async {
        // Your sign-in hands you the token. Fixture mode accepts any JWT-shaped string.
        let token = showcase.settings.mode == .live ? pastedJwt.trimmingCharacters(in: .whitespacesAndNewlines) : sampleToken()
        guard !token.isEmpty else { return }
        identifyResult = await showcase.mos.identify(userJWT: token)
        await decideNext()
    }

    private func signOut() async {
        identifyResult = await showcase.mos.identify(userJWT: nil)
        await decideNext()
    }

    private func decideNext() async {
        let result = await showcase.mos.decide(resource: Resource(id: "article/1"))
        decision = result
        anonymousBefore = await showcase.mos.anonymousIdentifier
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"article/1\") after identify")
    }

    /// An unsigned token for fixture mode: `sub` is the signed-in reader.
    private func sampleToken() -> String {
        let now = Int(Date().timeIntervalSince1970)
        return FixtureTransport.fakeJWT(["sub": "sample-user-1", "name": "Sample User", "iat": now, "exp": now + 3600])
    }
}
