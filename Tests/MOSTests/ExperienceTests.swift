import Foundation
import Testing
@testable import MonetizationOS

@Suite("Experiences and offers")
struct ExperienceTests {
    static let futureMs: Int64 = 1_893_456_000_000

    static let offer: JSONValue = [
        "id": "offer_1",
        "presentation": ["headline": "Go premium", "storeProductId": "com.example.monthly"],
        "redemptionSchema": "custom:purchase",
        "token": .string(Tokens.offer(expirationMsUtc: futureMs)),
    ]

    @Test("experiences: a JSON object decodes as native without mos-offer-slots, schema nil")
    func jsonObject() throws {
        let json: JSONValue = ["title": "Subscribe", "mos-offer-slots": [["type": "single", "offer": Self.offer]]]
        guard case .native(let content, let schema, let offers) = try #require(Experience.decode(json)) else {
            Issue.record("expected native")
            return
        }
        #expect(content == ["title": "Subscribe"])
        #expect(schema == nil)
        #expect(offers.count == 1)
        #expect(offers.first?.type == "single")
        #expect(offers.first?.offer?.id == "offer_1")
    }

    @Test("experiences: an object with no slots has no offers; an empty object is nil")
    func emptyObject() {
        #expect(Experience.decode(["title": "x"]) == .native(content: ["title": "x"], schema: nil, offers: []))
        #expect(Experience.decode([:]) == nil)
    }

    @Test("experiences: html and text items concatenate in order, text HTML-escaped, no offers")
    func webContent() {
        let json: JSONValue = [
            ["type": "html", "content": "<p>Hi</p>"],
            ["type": "text", "content": "Tom & \"Jerry\" <b>'s</b>"],
            ["type": "html", "content": "<a href=\"mos://close\">x</a>"],
        ]
        #expect(Experience.decode(json) == .web(
            html: "<p>Hi</p>Tom &amp; &quot;Jerry&quot; &lt;b&gt;&#39;s&lt;/b&gt;<a href=\"mos://close\">x</a>"
        ))
    }

    @Test("experiences: exactly one element item decodes as native with its schema and slots")
    func element() {
        let json: JSONValue = [[
            "type": "element", "schema": "com.example.paywall/v1",
            "props": ["title": "Subscribe", "mos-offer-slots": [["type": "single", "offer": .null]]],
        ]]
        #expect(Experience.decode(json) == .native(
            content: ["title": "Subscribe"], schema: "com.example.paywall/v1", offers: [OfferSlot(type: "single", offer: nil)]
        ))
    }

    @Test("experiences: empty, mixed, unknown-type and malformed arrays are nil", arguments: [
        [],
        [["type": "html", "content": "<p>x</p>"], ["type": "element", "schema": "s", "props": [:]]],
        [["type": "element", "schema": "s", "props": [:]], ["type": "element", "schema": "s", "props": [:]]],
        [["type": "video", "content": "x"]],
        [["type": "html"]],
        [["type": "html", "content": 3]],
        [["type": "element", "props": [:]]],
        [["type": "element", "schema": "s", "props": "x"]],
        ["<p>x</p>"],
    ] as [JSONValue])
    func notAnExperience(json: JSONValue) {
        #expect(Experience.decode(json) == nil)
    }

    @Test("experiences: strings, numbers, booleans and null are nil", arguments: ["x", 1, true, .null] as [JSONValue])
    func scalars(json: JSONValue) {
        #expect(Experience.decode(json) == nil)
    }

    @Test("experiences: offer fields, storeProductID and expiresAt read from the token payload")
    func offerFields() throws {
        let offer = try #require(offerSlots([["type": "single", "offer": Self.offer]]).first?.offer)
        #expect(offer.id == "offer_1")
        #expect(offer.presentation == ["headline": "Go premium", "storeProductId": "com.example.monthly"])
        #expect(offer.redemptionSchema == "custom:purchase")
        #expect(offer.token == Tokens.offer(expirationMsUtc: Self.futureMs))
        #expect(offer.storeProductID == "com.example.monthly")
        #expect(offer.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    }

    @Test("experiences: no expiry, an undecodable token, a non-string storeProductId and no presentation")
    func offerOptionals() throws {
        let slots = offerSlots([
            ["type": "single", "offer": ["id": "a", "token": .string(Tokens.offer(expirationMsUtc: nil)), "presentation": ["storeProductId": 7]]],
            ["type": "single", "offer": ["id": "b", "token": "not.a.jwt"]],
        ])
        #expect(slots.map { $0.offer?.id } == ["a", "b"])
        #expect(slots[0].offer?.expiresAt == nil)
        #expect(slots[0].offer?.storeProductID == nil)
        #expect(slots[1].offer?.expiresAt == nil)
        #expect(slots[1].offer?.presentation == [:])
        #expect(slots[1].offer?.redemptionSchema == nil)
    }

    @Test("experiences: a null offer, or one without a string id or token, keeps its slot with offer nil")
    func nullOffers() {
        let slots = offerSlots([
            ["type": "single", "offer": .null],
            ["type": "single"],
            ["type": "single", "offer": ["token": "t.t.t"]],
            ["type": "single", "offer": ["id": "x"]],
            ["type": "single", "offer": ["id": 1, "token": "t.t.t"]],
        ])
        #expect(slots == Array(repeating: OfferSlot(type: "single", offer: nil), count: 5))
    }

    @Test("experiences: malformed slots are skipped; a non-array gives no slots")
    func malformedSlots() {
        let slots = offerSlots(["x", 1, .null, ["offer": Self.offer], ["type": 3], ["type": "carousel", "offer": .null]])
        #expect(slots == [OfferSlot(type: "carousel", offer: nil)])
        #expect(offerSlots(["type": "single"]) == [])
        #expect(offerSlots(.null) == [])
    }

    @Test("experiences: decision.experience reads surfaceBehavior.properties or a component's properties")
    func fromDecision() throws {
        var json = Decisions.make(surfaceProperties: ["paywall": [["type": "html", "content": "<p>Wall</p>"]], "entitled": false])
        json = .object(json.objectValue!.merging(["componentBehaviors": ["inline": ["properties": ["card": ["title": "Card"]], "metadata": [:]]]]) { $1 })
        let decision = try #require(Decision(json: json))
        #expect(decision.experience("paywall") == .web(html: "<p>Wall</p>"))
        #expect(decision.experience("card", component: "inline") == .native(content: ["title": "Card"], schema: nil, offers: []))
        #expect(decision.experience("card") == nil)
        #expect(decision.experience("paywall", component: "inline") == nil)
        #expect(decision.experience("card", component: "missing") == nil)
        #expect(decision.experience("entitled") == nil)
    }

    struct Paywall: Decodable, Equatable {
        let title: String
        let bullets: [String]
        let trialDays: Int
        let badge: String?
    }

    @Test("experiences: typed decode of native content; web throws")
    func typedDecode() throws {
        let experience = try #require(Experience.decode([
            "title": "Subscribe", "bullets": ["Ad free", "Offline"], "trialDays": 7, "extra": true,
            "mos-offer-slots": [["type": "single", "offer": Self.offer]],
        ]))
        #expect(try experience.decode(Paywall.self) == Paywall(title: "Subscribe", bullets: ["Ad free", "Offline"], trialDays: 7, badge: nil))
        let typed: Paywall = try experience.decode()
        #expect(typed.trialDays == 7)
        #expect(throws: DecodingError.self) { try Experience.web(html: "").decode(Paywall.self) }
        #expect(throws: DecodingError.self) { try Experience.native(content: ["title": 1], schema: nil, offers: []).decode(Paywall.self) }
    }
}
