import DigiaEngage

/// Routes a presentation's signals and terminal outcome to MoEngage.
///
/// MoEngage infers nothing about a self-handled campaign: shown, clicked and
/// dismissed are all the app's to report. The v2 split is what decides *when*:
/// shown and clicked are **signals** — best-effort, mid-flight — while dismissed
/// rides the terminal path, and the cache entry that every one of these calls
/// needs is freed there, on **both** outcome arms. That binding is the whole
/// point: before v2 the entry was evicted only on a dismissal that a dropped
/// campaign never produced, so every campaign Digia declined leaked its entry —
/// and the entry holds a MoEngage SDK object, not a string.
@MainActor
final class MoEngageEventDispatcher {
    private let client: MoEngageClient
    private let cache: ICampaignCache
    private let log = DigiaLogger("ME")

    init(client: MoEngageClient, cache: ICampaignCache) {
        self.client = client
        self.cache = cache
    }

    /// The experience became visible.
    ///
    /// Shown only. Inline content used to be marked dismissed here too, on the
    /// reasoning that it has no close affordance and so no terminal moment of
    /// its own. It does: ``CampaignPresentation/outcome`` always settles, and
    /// ``experienceEnded(_:displayed:)`` binds to it. Reporting a dismissal
    /// while the campaign is still on screen told MoEngage something untrue,
    /// and it rested on the marketer typing `"type":"inline"` into the MoEngage
    /// payload — a field Digia has no concept of, which this plugin and its
    /// Kotlin twin defaulted opposite ways when it was absent. The Flutter
    /// plugin never had the branch.
    func campaignShown(_ payload: CEPTriggerPayload) {
        guard let campaign = campaign(for: payload) else { return }
        log.i("CEP impression marked (selfHandledShown)", campaign: payload.campaignKey)
        client.markShown(campaign)
    }

    /// A qualifying interaction with the experience.
    func campaignClicked(_ payload: CEPTriggerPayload) {
        guard let campaign = campaign(for: payload) else { return }
        log.i("CEP click marked (selfHandledClicked)", campaign: payload.campaignKey)
        client.markClicked(campaign)
    }

    /// The presentation settled. Terminal, and reached on **both** outcome arms.
    ///
    /// - Parameter displayed: whether the experience reached the screen — the
    ///   `dismissed` arm of `PresentationOutcome`. A campaign that never
    ///   displayed has nothing to dismiss, so MoEngage is told nothing; the
    ///   cache entry goes either way.
    func experienceEnded(_ payload: CEPTriggerPayload, displayed: Bool) {
        let campaignId = payload.cepCampaignId
        defer { cache.remove(campaignId: campaignId) }

        guard let campaign = campaign(for: payload) else { return }
        guard displayed else {
            log.d("Nothing dispatched — the campaign never displayed (cepId=\(campaignId))", campaign: payload.campaignKey)
            return
        }
        log.i("CEP dismiss marked (selfHandledDismissed)", campaign: payload.campaignKey)
        client.markDismissed(campaign)
    }

    // MARK: - Helpers

    private func campaign(for payload: CEPTriggerPayload) -> MoEngageSelfHandledCampaign? {
        guard let campaign = cache.get(campaignId: payload.cepCampaignId) else {
            log.w("No cached campaign for cepId=\(payload.cepCampaignId)", campaign: payload.campaignKey)
            return nil
        }
        return campaign
    }
}
