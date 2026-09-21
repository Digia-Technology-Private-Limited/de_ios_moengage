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
    }

    @Test("ignores a key that is present but not a usable string")
    func unusableKey() {
        #expect(mapper.map(campaign(#"{"digiaKey":"   "}"#)).campaignKey == "camp_1")
        #expect(mapper.map(campaign(#"{"digiaKey":42}"#)).campaignKey == "camp_1")
    }
}
