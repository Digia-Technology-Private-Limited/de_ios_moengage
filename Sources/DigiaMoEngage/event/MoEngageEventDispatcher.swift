import DigiaEngage
import MoEngageInApps
import os.log

/// Routes Digia overlay lifecycle events to MoEngage analytics.
///
/// ## Strategy pattern
/// Event dispatch is a dedicated responsibility, isolated here so that
/// `MoEngagePlugin` is **closed for modification** when new event types are
/// added. Only this class is updated — the plugin orchestrator is unchanged.
///
/// Swift's exhaustive `switch` over `DigiaExperienceEvent` provides compile-time
/// safety: adding a new case causes a compile error here rather than a silent
/// runtime miss.
///
/// ## Dependencies
/// - `MoEngageInApp.shared`: MoEngage lifecycle APIs (shown / clicked / dismissed).
/// - `ICampaignCache`: resolves the cached `InAppSelfHandledCampaign` required
///   by the MoEngage APIs, and evicts entries post-dismiss.
final class MoEngageEventDispatcher {
    private let cache: ICampaignCache
    private let logger = Logger(subsystem: "com.digia.moengage", category: "MoEngageEventDispatcher")

    init(cache: ICampaignCache) {
        self.cache = cache
    }

    /// Dispatches the lifecycle event reported by Core.
    /// Returns true if dispatched, false if campaignId is missing or not cached.
    @discardableResult
    func dispatch(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) -> Bool {
        guard let campaignId = payload.cepMetadata["campaignId"] else {
            logger.warning("dispatch: missing campaignId in cepMetadata")
            return false
        }
        return dispatchInAppEvent(event, campaignId: campaignId)
    }

    /// Handles cached campaign lifecycle events.
    private func dispatchInAppEvent(_ event: DigiaExperienceEvent, campaignId: String) -> Bool {
        guard let data = cache.get(campaignId: campaignId) else {
            logger.warning("dispatchInAppEvent: no cached data for campaignId=\(campaignId)")
            return false
        }
        switch event {
        case .impressed:
            MoEngageSDKInApp.sharedInstance.selfHandledShown(campaignInfo: data)
            logger.debug("dispatched: selfHandledShown — campaignId=\(campaignId)")
        case .clicked:
            MoEngageSDKInApp.sharedInstance.selfHandledClicked(campaignInfo: data)
            logger.debug("dispatched: selfHandledClicked — campaignId=\(campaignId)")
        case .dismissed:
            MoEngageSDKInApp.sharedInstance.selfHandledDismissed(campaignInfo: data)
            cache.remove(campaignId: campaignId)
            logger.debug("dispatched: selfHandledDismissed — campaignId=\(campaignId)")
        }
        return true
    }
}
