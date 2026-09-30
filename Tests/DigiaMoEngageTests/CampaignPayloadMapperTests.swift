@testable import DigiaEngage
@testable import DigiaMoEngage
import Foundation
import Testing

/// The coupling question: which string does Digia look the campaign up by?
///
/// MoEngage's own campaignId is a generated hex id (`6ab16585047a79452da69b09`), and a mapper
/// that hands that to core produces "no campaign for key" for every correctly-authored
/// campaign — the failure these exist to catch, because it is silent at the CEP boundary and
/// only visible in a log line far downstream. The key the marketer typed lives in the
/// self-handled JSON, and the aliases below are the same set CleverTap accepts.
///
/// Twin of `CampaignPayloadMapperTest.kt` in the Android plugin.
struct CampaignPayloadMapperTests {

    private let mapper = CampaignPayloadMapper()

    private func campaign(_ content: String, id: String = "camp_1") -> FakeCampaign {
        FakeCampaign(campaignId: id, campaignContent: content)
    }

    @Test("reads the campaign key the marketer typed, in every accepted spelling")
    func everySpelling() {
        for spelling in CampaignPayloadMapper.campaignKeyNames {
            let payload = mapper.map(
                campaign(#"{"\#(spelling)":"welcome_nudge"}"#, id: "6ab16585047a79452da69b09"))
            #expect(payload.campaignKey == "welcome_nudge", "spelling \(spelling)")
        }
    }

    @Test("keeps MoEngage's own id as the CEP identity, not as the coupling key")
    func idIsIdentityNotKey() {
        let payload = mapper.map(
            campaign(#"{"digiaKey":"welcome_nudge"}"#, id: "6ab16585047a79452da69b09"))

        #expect(payload.cepCampaignId == "6ab16585047a79452da69b09")
        #expect(payload.campaignKey == "welcome_nudge")
        #expect(payload.cepMetadata["campaignId"] == "6ab16585047a79452da69b09")
    }

    @Test("trims a key the marketer left whitespace around")
    func trims() {
        #expect(mapper.map(campaign(#"{"digiaKey":"  welcome_nudge  "}"#)).campaignKey
            == "welcome_nudge")
    }

    @Test("prefers the earlier spelling when a payload carries two")
    func priorityOrder() {
        #expect(mapper.map(campaign(#"{"campaign_key":"second","digiaKey":"first"}"#)).campaignKey
            == "first")
    }

    // MARK: - The fallbacks: a total mapper, never a throw

    @Test("falls back to the MoEngage id when the marketer typed no key")
    func noKeyAtAll() {
        #expect(mapper.map(campaign(#"{"title":"Hello"}"#)).campaignKey == "camp_1")
    }

    @Test("falls back to the MoEngage id when the JSON is malformed")
    func malformedJson() {
        let payload = mapper.map(campaign("{not json at all"))

        #expect(payload.campaignKey == "camp_1")
        #expect(payload.cepMetadata["campaignId"] == "camp_1")
        #expect(!payload.corrupt)
    }

    @Test("marks a malformed JSON that names a Digia key as corrupt")
    func corruptJson() {
        #expect(mapper.map(campaign(#"{"digiaKey":"promo"#)).corrupt)
        #expect(!mapper.map(campaign(#"{"digiaKey":"promo"}"#)).corrupt)
    }

    @Test("ignores a key that is present but not a usable string")
    func unusableKey() {
        #expect(mapper.map(campaign(#"{"digiaKey":"   "}"#)).campaignKey == "camp_1")
        #expect(mapper.map(campaign(#"{"digiaKey":42}"#)).campaignKey == "camp_1")
    }

    // MARK: - Variables

    @Test("reads runtime variables, preferring variables over the older args")
    func variablesBeatArgs() {
        let both = campaign(
            #"{"digiaKey":"k","variables":{"name":"Priya"},"args":{"name":"Stale"}}"#)
        let argsOnly = campaign(#"{"digiaKey":"k","args":{"name":"Priya"}}"#)

        #expect(mapper.map(both).variables == ["name": "Priya"])
        #expect(
            mapper.map(argsOnly).variables == ["name": "Priya"],
            "args is the older spelling, still live")
    }

    @Test("renders a number as the integer the marketer typed")
    func numbersAreNotBooleans() {
        // Every JSON number arrives as an NSNumber, and `1 as? Bool` succeeds — the naive
        // switch answered "true" for an authored count of 1.
        let payload = mapper.map(
            campaign(#"{"digiaKey":"k","variables":{"count":1,"price":2.5,"onSale":true}}"#))

        #expect(payload.variables == ["count": "1", "price": "2.5", "onSale": "true"])
    }

    @Test("reads variables the dashboard could only store as text")
    func variablesAsText() {
        // A marketer who pastes the blob into a string field gets an object all the same.
        let payload = mapper.map(
            campaign(#"{"digiaKey":"k","variables":"{\"name\":\"Priya\",\"count\":5}"}"#))

        #expect(payload.variables == ["name": "Priya", "count": "5"])
    }

    @Test("drops values that cannot be interpolated")
    func dropsNonScalars() {
        let payload = mapper.map(
            campaign(
                #"{"digiaKey":"k","variables":{"tags":["a"],"nested":{"x":1},"blank":"","gone":null,"keep":"y"}}"#
            ))

        #expect(payload.variables == ["keep": "y"])
    }

    @Test("carries no variables when the marketer authored none")
    func noVariables() {
        #expect(mapper.map(campaign(#"{"digiaKey":"k"}"#)).variables == nil)
        #expect(mapper.map(campaign(#"{"variables":"oops"}"#)).variables == nil)
    }
}
