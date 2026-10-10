/// In-memory implementation of `ICampaignCache`.
///
/// Backed by a plain `Dictionary`; entries are evicted per-campaign on
/// `remove(campaignId:)` when the presentation settles, and globally on
/// `clear()` at detach.
///
/// Swap this with an LRU or persistent cache by implementing `ICampaignCache`
/// and injecting it into `MoEngagePlugin` — no other code changes required.
public final class CampaignCache: ICampaignCache {
    public init() {}

    private var store: [String: MoEngageSelfHandledCampaign] = [:]

    public func put(campaignId: String, data: MoEngageSelfHandledCampaign) {
        store[campaignId] = data
    }

    public func get(campaignId: String) -> MoEngageSelfHandledCampaign? {
        store[campaignId]
    }

    public func remove(campaignId: String) {
        store.removeValue(forKey: campaignId)
    }

    public func clear() {
        store.removeAll()
    }

    public var count: Int { store.count }

    public var campaignIds: [String] { Array(store.keys) }
}
