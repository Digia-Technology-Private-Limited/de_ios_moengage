@testable import DigiaEngage
@testable import DigiaMoEngage
import Foundation

/// A MoEngage self-handled campaign, without MoEngage.
///
/// This is what the seam buys: the real `MoEngageInAppSelfHandledCampaign`
/// cannot be built in a test without also building `MoEngageInAppRules`.
final class FakeCampaign: MoEngageSelfHandledCampaign {
    let campaignId: String
    let campaignName: String
    let campaignContent: String

    init(campaignId: String = "camp_1", campaignName: String = "Onboarding", campaignContent: String) {
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.campaignContent = campaignContent
    }

    /// A modal campaign — has a terminal moment of its own.
    static func modal(campaignId: String = "camp_1", campaignKey: String = "onboarding_tip") -> FakeCampaign {
        FakeCampaign(
            campaignId: campaignId,
            campaignContent: #"{"digiaKey":"\#(campaignKey)"}"#
        )
    }

    /// An inline campaign. Identical to any other from MoEngage's side — what it
    /// renders as is Digia's business, and the CEP payload says nothing about it.
    static func inline(campaignId: String = "camp_inline") -> FakeCampaign {
        FakeCampaign(campaignId: campaignId, campaignContent: #"{"digiaKey":"home_banner"}"#)
    }
}

/// Records every MoEngage call the plugin makes, and lets a test push the
/// callback MoEngage would push.
@MainActor
final class FakeMoEngageClient: MoEngageClient {
    private(set) var shown: [String] = []
    private(set) var clicked: [String] = []
    private(set) var dismissed: [String] = []
    private(set) var contexts: [[String]] = []
    private(set) var fetchCount = 0
    private(set) var listenerCleared = false

    /// Non-nil installs, mirroring the real client: it keeps the init-time
    /// adapter across attach and only reinstalls after a detach cleared it.
    private(set) var installCount = 0

    private var listener: (@MainActor (MoEngageSelfHandledCampaign) -> Void)?

    /// Runs from inside ``markDismissed(_:)``, so a test can make MoEngage's
    /// own terminal call misbehave (scenario C5).
    var onMarkDismissed: ((MoEngageSelfHandledCampaign) -> Void)?

    /// Pushes a campaign the way MoEngage's self-handled delegate would.
    func emit(_ campaign: MoEngageSelfHandledCampaign) { listener?(campaign) }

    var hasListener: Bool { listener != nil }

    // MARK: - MoEngageClient

    func setSelfHandledListener(_ listener: (@MainActor (MoEngageSelfHandledCampaign) -> Void)?) {
        guard let listener else {
            self.listener = nil
            listenerCleared = true
            return
        }
        guard self.listener == nil else { return }
        self.listener = listener
        installCount += 1
    }

    func fetchSelfHandledInApp() { fetchCount += 1 }

    func setCurrentContexts(_ contexts: [String]) { self.contexts.append(contexts) }

    func markShown(_ campaign: MoEngageSelfHandledCampaign) { shown.append(campaign.campaignId) }

    func markClicked(_ campaign: MoEngageSelfHandledCampaign) { clicked.append(campaign.campaignId) }

    func markDismissed(_ campaign: MoEngageSelfHandledCampaign) {
        dismissed.append(campaign.campaignId)
        onMarkDismissed?(campaign)
    }
}
