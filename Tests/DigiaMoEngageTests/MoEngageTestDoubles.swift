@testable import DigiaEngage
@testable import DigiaMoEngage
import Foundation

/// Stands in for Digia core.
///
/// Built on the real ``PresentationController``, so the contract's own
/// guarantees — exactly-once settlement, no signals after the outcome,
/// `holdReleased` settling at or before `outcome` — hold in these tests rather
/// than being re-implemented by a fake that could drift from them.
@MainActor
final class FakeCEPHost: DigiaCEPHost {
    /// When set, `deliver` returns an already-settled presentation.
    var syncDrop: DropReason?

    private(set) var delivered: [CEPTriggerPayload] = []
    private(set) var controllers: [PresentationController] = []
    private var nextId = 0

    // `nonisolated`: the plugin suites use a FakeCEPHost as a default argument,
    // which Swift evaluates outside the main actor.
    nonisolated init(syncDrop: DropReason? = nil) {
        self.syncDrop = syncDrop
    }

    func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation {
        delivered.append(trigger)
        nextId += 1
        let controller = PresentationController(id: "p-\(nextId)", trigger: trigger)
        controllers.append(controller)
        if let syncDrop {
            controller.settle(.dropped(reason: syncDrop, detail: nil))
        }
        return controller.presentation
    }

    /// The controller for the most recent delivery — the test's handle on core.
    var last: PresentationController { controllers[controllers.count - 1] }
}

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
    static func modal(campaignId: String = "camp_1", placementKey: String = "onboarding_tip") -> FakeCampaign {
        FakeCampaign(
            campaignId: campaignId,
            campaignContent: #"{"type":"dialog","placementKey":"\#(placementKey)","viewId":"v1"}"#
        )
    }

    /// An inline campaign — no close affordance, so its shown is its dismissed.
    static func inline(campaignId: String = "camp_inline") -> FakeCampaign {
        FakeCampaign(
            campaignId: campaignId,
            campaignContent: #"{"type":"inline","placementKey":"home_banner","viewId":"v2"}"#
        )
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

    private var listener: (@MainActor (MoEngageSelfHandledCampaign) -> Void)?

    /// Pushes a campaign the way MoEngage's self-handled delegate would.
    func emit(_ campaign: MoEngageSelfHandledCampaign) { listener?(campaign) }

    var hasListener: Bool { listener != nil }

    // MARK: - MoEngageClient

    func setSelfHandledListener(_ listener: (@MainActor (MoEngageSelfHandledCampaign) -> Void)?) {
        self.listener = listener
        if listener == nil { listenerCleared = true }
    }

    func fetchSelfHandledInApp() { fetchCount += 1 }

    func setCurrentContexts(_ contexts: [String]) { self.contexts.append(contexts) }

    func markShown(_ campaign: MoEngageSelfHandledCampaign) { shown.append(campaign.campaignId) }

    func markClicked(_ campaign: MoEngageSelfHandledCampaign) { clicked.append(campaign.campaignId) }

    func markDismissed(_ campaign: MoEngageSelfHandledCampaign) { dismissed.append(campaign.campaignId) }
}

/// Lets main-actor continuations resumed by a settlement actually run.
///
/// The plugin binds its terminal work to `await presentation.outcome.value`, so
/// a settlement made by a test resumes a task that runs on the *next* main-actor
/// turn. Synchronous drops and plugin-initiated terminations do not need this.
func drainMainActor(_ turns: Int = 5) async {
    for _ in 0..<turns { await Task.yield() }
}
