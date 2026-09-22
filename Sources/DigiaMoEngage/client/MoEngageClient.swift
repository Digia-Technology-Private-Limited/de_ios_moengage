import Foundation
import MoEngageCore
import MoEngageInApps

/// One MoEngage self-handled campaign, reduced to the three fields this plugin
/// reads.
///
/// The seam exists so the whole plugin — mapper, cache, dispatcher,
/// orchestration — runs under XCTest against a plain fake. MoEngage's own
/// campaign class cannot be constructed in a test without also constructing
/// `MoEngageInAppRules` and a `Date`-based expiry, and a suite that needs the
/// real SDK to assert "did `selfHandledShown` reach MoEngage?" is a suite that
/// will not be run.
public protocol MoEngageSelfHandledCampaign: AnyObject {
    var campaignId: String { get }
    var campaignName: String { get }

    /// The marketer-authored JSON payload.
    var campaignContent: String { get }
}

extension MoEngageInAppSelfHandledCampaign: MoEngageSelfHandledCampaign {}

/// The MoEngage SDK calls this plugin makes.
///
/// Kept behind a protocol so no plugin logic touches
/// `MoEngageSDKInApp.sharedInstance` directly, and so the one place that talks
/// to the real SDK is obvious. Mirrors `CleverTapClient` in the CleverTap
/// plugin.
@MainActor
public protocol MoEngageClient: AnyObject {
    /// Installs (or, with `nil`, drops) the self-handled in-app listener.
    func setSelfHandledListener(_ listener: (@MainActor (MoEngageSelfHandledCampaign) -> Void)?)

    /// Asks MoEngage for a campaign eligible for the current contexts.
    func fetchSelfHandledInApp()

    /// Tells MoEngage which in-app contexts the app is currently in.
    func setCurrentContexts(_ contexts: [String])

    /// Impression. MoEngage never infers this for a self-handled campaign.
    func markShown(_ campaign: MoEngageSelfHandledCampaign)

    /// Click. Likewise app-owned.
    func markClicked(_ campaign: MoEngageSelfHandledCampaign)

    /// Terminal. Frees MoEngage's own bookkeeping for the campaign.
    func markDismissed(_ campaign: MoEngageSelfHandledCampaign)
}

// MARK: - Real SDK implementation

/// ``MoEngageClient`` backed by `MoEngageSDKInApp.sharedInstance`.
@MainActor
public final class MoEngageSdkClient: MoEngageClient {

    /// Retained because MoEngage holds its in-app delegate weakly.
    private var delegateAdapter: SelfHandledDelegateAdapter?

    public init() {}

    public func setSelfHandledListener(_ listener: (@MainActor (MoEngageSelfHandledCampaign) -> Void)?) {
        guard let listener else {
            delegateAdapter = nil
            return
        }
        let adapter = SelfHandledDelegateAdapter(onCampaign: listener)
        delegateAdapter = adapter
        MoEngageSDKInApp.sharedInstance.setInAppDelegate(adapter)
    }

    public func fetchSelfHandledInApp() {
        let adapter = delegateAdapter
        Self.requestSelfHandledInApp(adapter: adapter)
    }

    nonisolated private static func requestSelfHandledInApp(adapter: SelfHandledDelegateAdapter?) {
        MoEngageSDKInApp.sharedInstance.getSelfHandledInApp { campaignInfo, _ in
            guard let campaignInfo else { return }
            // MoEngage completes on an unspecified queue, and its campaign type
            // is not Sendable — hop before anything else touches it.
            nonisolated(unsafe) let campaign = campaignInfo
            onMainActor { adapter?.deliver(campaign) }
        }
    }

    public func setCurrentContexts(_ contexts: [String]) {
        MoEngageSDKInApp.sharedInstance.setCurrentInAppContexts(contexts)
    }

    public func markShown(_ campaign: MoEngageSelfHandledCampaign) {
        guard let native = campaign as? MoEngageInAppSelfHandledCampaign else { return }
        MoEngageSDKInApp.sharedInstance.selfHandledShown(campaignInfo: native)
    }

    public func markClicked(_ campaign: MoEngageSelfHandledCampaign) {
        guard let native = campaign as? MoEngageInAppSelfHandledCampaign else { return }
        MoEngageSDKInApp.sharedInstance.selfHandledClicked(campaignInfo: native)
    }

    public func markDismissed(_ campaign: MoEngageSelfHandledCampaign) {
        guard let native = campaign as? MoEngageInAppSelfHandledCampaign else { return }
        MoEngageSDKInApp.sharedInstance.selfHandledDismissed(campaignInfo: native)
    }
}

/// Bridges `MoEngageInAppNativeDelegate` — an Obj-C protocol requiring
/// `NSObjectProtocol` — to a closure.
///
/// `@unchecked Sendable` is load-bearing and safe: the only stored property is a
/// `let` set in `init` and never mutated, so there is no shared mutable state to
/// race on. MoEngage 10.x delivers `selfHandledInAppTriggered` from a nonisolated
/// context, and hopping to the main actor from there means capturing `self` —
/// which Swift 6 rejects for a non-Sendable class ("sending 'self' risks causing
/// data races"). Under MoEngage 9.x the callback's isolation let this compile
/// without the annotation; the behaviour is unchanged either way.
private final class SelfHandledDelegateAdapter: NSObject, MoEngageInAppNativeDelegate, @unchecked Sendable {
    private let onCampaign: @MainActor (MoEngageSelfHandledCampaign) -> Void

    init(onCampaign: @escaping @MainActor (MoEngageSelfHandledCampaign) -> Void) {
        self.onCampaign = onCampaign
    }

    @MainActor
    func deliver(_ campaign: MoEngageInAppSelfHandledCampaign) {
        onCampaign(campaign)
    }

    func inAppShown(withCampaignInfo inappCampaign: MoEngageInAppCampaign,
                    forAccountMeta accountMeta: MoEngageAccountMeta) {}

    func inAppClicked(withCampaignInfo inappCampaign: MoEngageInAppCampaign,
                      andNavigationActionInfo navigationAction: MoEngageInAppNavigationAction,
                      forAccountMeta accountMeta: MoEngageAccountMeta) {}

    func inAppClicked(withCampaignInfo inappCampaign: MoEngageInAppCampaign,
                      andCustomActionInfo customAction: MoEngageInAppAction,
                      forAccountMeta accountMeta: MoEngageAccountMeta) {}

    func inAppDismissed(withCampaignInfo inappCampaign: MoEngageInAppCampaign,
                        forAccountMeta accountMeta: MoEngageAccountMeta) {}

    func selfHandledInAppTriggered(withInfo inappCampaign: MoEngageInAppSelfHandledCampaign,
                                   forAccountMeta accountMeta: MoEngageAccountMeta) {
        nonisolated(unsafe) let campaign = inappCampaign
        onMainActor { [weak self] in self?.deliver(campaign) }
    }
}

/// Runs `work` on the main actor, inline when the caller is already there.
///
/// MoEngage delivers in-app callbacks on an unspecified queue. Hopping
/// unconditionally would defer every delivery by a turn, which lets `detach()`
/// run between MoEngage handing over a campaign and the plugin seeing it.
/// Mirrors the CleverTap and WebEngage plugins' helper of the same name.
func onMainActor(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
