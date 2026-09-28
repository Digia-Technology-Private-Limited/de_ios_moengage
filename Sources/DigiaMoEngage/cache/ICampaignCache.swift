/// Abstraction for MoEngage self-handled campaign data caching.
///
/// Decouples lifecycle-event correlation from any particular storage
/// strategy. An in-memory map, an LRU cache, or a persistent store may be
/// injected without touching `MoEngagePlugin` or `MoEngageEventDispatcher`.
///
/// The key is always the core-minted presentation id, never MoEngage's
/// campaign id: the campaign id repeats across deliveries, and keying by it
/// would let a second copy of a live campaign steal the first one's dismissal.
/// Parameter labels keep the historical `campaignId` name so existing
/// implementations keep compiling.
public protocol ICampaignCache: AnyObject {
    /// Stores `data` keyed by `campaignId`.
    func put(campaignId: String, data: MoEngageSelfHandledCampaign)

    /// Returns the cached `MoEngageSelfHandledCampaign` for `campaignId`,
    /// or `nil` when absent.
    func get(campaignId: String) -> MoEngageSelfHandledCampaign?

    /// Removes the entry for `campaignId`.
    ///
    /// Called when the presentation's `outcome` settles — on **both** arms, so a
    /// campaign Digia dropped cannot leak its entry any more than one that
    /// displayed and closed.
    func remove(campaignId: String)

    /// Evicts all entries (called on detach).
    func clear()

    /// Number of currently cached campaigns.
    var count: Int { get }

    /// Read-only list of currently cached campaign IDs (for diagnostics).
    var campaignIds: [String] { get }
}
