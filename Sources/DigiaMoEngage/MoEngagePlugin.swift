import DigiaEngage
import Foundation
import os.log

/// Digia CEP plugin for MoEngage (iOS).
///
/// Bridges MoEngage's Self-Handled In-App campaign system into Digia's
/// rendering engine.
///
/// ## Usage
/// ```swift
/// // AppDelegate / SwiftUI App init
/// MoEngage.sharedInstance.initializeDefault(with: config, in: application, withLaunchOptions: launchOptions)
///
/// Digia.initialize(config: DigiaConfig(apiKey: "prod_xxxx"))
/// Digia.register(MoEngagePlugin())
/// ```
///
/// ## What this plugin holds, and when it lets go
///
/// MoEngage has no global slot and no queue that a missed call can stall — what
/// it hands over is a campaign object, and the plugin caches it because every
/// later MoEngage call (`selfHandledShown`, `…Clicked`, `…Dismissed`) needs it
/// back. That cache entry is the resource here, and its lifetime is bound to the
/// presentation's `outcome`: it is freed when the presentation settles, on
/// **both** arms. Before v2 it was freed only on a dismissal, which a dropped
/// campaign never produces, so every campaign Digia declined leaked an SDK
/// object for the life of the session.
///
/// ## Design
/// - **SRP** — mapping, caching, event dispatch and the SDK seam each live in
///   their own type.
/// - **DIP** — depends on `MoEngageClient`, `ICampaignCache` and
///   `ICampaignPayloadMapper`, never on `MoEngageSDKInApp.sharedInstance`. That
///   is what lets the whole plugin run under XCTest with a fake client.
@MainActor
public final class MoEngagePlugin: DigiaCEPPlugin {

    // MARK: - Public

    public let id = "moengage"

    /// How long a campaign may sit buffered waiting for `Digia.register()`
    /// before it is dropped.
    ///
    /// Buffering at all is what lets an app-launch campaign survive the gap
    /// between MoEngage triggering it and Digia being registered — the listener
    /// is installed at construction, which can be earlier than `attach`.
    /// Bounding it is what stops a session that never registers Digia from
    /// accumulating MoEngage campaign objects for its whole lifetime.
    ///
    /// Spec §10.5 G-d: this timer, and only this timer, stays in the plugin.
    public static let attachGrace: TimeInterval = 10

    /// Bound on the pre-attach buffer. Unbounded buffering is the bug, not the
    /// feature.
    private static let maxBufferedCampaigns = 5

    // MARK: - Private

    private let client: MoEngageClient
    private let cache: ICampaignCache
    private let mapper: ICampaignPayloadMapper
    private let dispatcher: MoEngageEventDispatcher

    private var host: DigiaCEPHost?

    /// Presentations this plugin still owns, keyed by MoEngage campaign id.
    ///
    /// Also the idempotency guard on the terminal path: `finish` removes the
    /// entry first, so the outcome task and `detach()` can race and only the
    /// first one does any work.
    private var live: [String: CampaignPresentation] = [:]

    /// Campaigns MoEngage triggered before any host attached.
    private var buffered: [MoEngageSelfHandledCampaign] = []

    private let log = DigiaLogger("ME")

    // MARK: - Init

    public convenience init() {
        self.init(client: MoEngageSdkClient())
    }

    /// Creates a `MoEngagePlugin`.
    ///
    /// `client`, `cache` and `mapper` are injectable — pass fakes in tests, or
    /// an alternative storage strategy in production.
    public init(
        client: MoEngageClient,
        cache: ICampaignCache = CampaignCache(),
        mapper: ICampaignPayloadMapper = CampaignPayloadMapper()
    ) {
        self.client = client
        self.cache = cache
        self.mapper = mapper
        self.dispatcher = MoEngageEventDispatcher(client: client, cache: cache)

        // Installed now, not in attach(), so a campaign MoEngage triggers while
        // Digia.initialize() is still in flight is buffered rather than lost.
        client.setSelfHandledListener { [weak self] campaign in
            self?.onCampaignTriggered(campaign)
        }
    }

    // MARK: - DigiaCEPPlugin

    public func attach(host: DigiaCEPHost) {
        guard self.host == nil else { return }
        self.host = host

        if !buffered.isEmpty {
            let pending = buffered
            buffered = []
            log.d("Flushing \(pending.count) campaign(s) buffered before attach")
            pending.forEach(deliver)
        }

        client.fetchSelfHandledInApp()
        log.i("Plugin attached — listening for self-handled in-app campaigns")
    }

    public func onScreenChanged(_ screenName: String) {
        client.setCurrentContexts([screenName])
        client.fetchSelfHandledInApp()
        log.d("Screen tracked (screen=\(screenName))")
    }

    public func detach() {
        // Core settles a plugin's presentations before detaching it, but the
        // tasks awaiting those outcomes have not necessarily run yet. This is
        // the last moment the plugin can free MoEngage's side and its own cache.
        for (campaignId, presentation) in live {   // a snapshot: `finish` mutates `live`
            // Read the outcome rather than assuming `false`: `cancel()` settles on the main
            // actor, inline, so by now the true terminal result is here. If core had already
            // settled this presentation as `dismissed` and only its awaiting task had yet to
            // run, hardcoding `false` silently dropped the final CEP marking for a campaign
            // the user really did see.
            presentation.cancel()
            finish(
                campaignId: campaignId,
                trigger: presentation.trigger,
                displayed: presentation.outcome.settledValue.map(didDisplay) ?? false
            )
        }
        live.removeAll()

        client.setSelfHandledListener(nil)
        buffered.removeAll()
        cache.clear()
        host = nil
        log.i("Plugin detached")
    }

    /// Not part of ``DigiaCEPPlugin`` — a plugin-level diagnostic a host app
    /// can call directly.
    public func healthCheck() -> DiagnosticReport {
        guard host != nil else {
            return DiagnosticReport(
                isHealthy: false,
                issue: "Plugin has no host — attach() has not been called.",
                resolution: "Call Digia.register(MoEngagePlugin()) before using the SDK."
            )
        }
        return DiagnosticReport(
            isHealthy: true,
            metadata: [
                "id":                 id,
                "attached":           "true",
                "livePresentations":  "\(live.count)",
                "cachedCampaigns":    "\(cache.count)",
                "cachedCampaignIds":  cache.campaignIds.joined(separator: ","),
            ]
        )
    }

    // MARK: - Delivery

    func onCampaignTriggered(_ campaign: MoEngageSelfHandledCampaign) {
        guard host != nil else {
            bufferUntilAttach(campaign)
            return
        }
        deliver(campaign)
    }

    /// Hands a campaign to Digia and binds MoEngage's side to the handle.
    ///
    /// Shown and clicked ride `onSignal`; the dismissal and the cache entry ride
    /// `outcome`. Nothing rides `holdReleased` — MoEngage has no hold to free
    /// early (spec §7.3).
    private func deliver(_ campaign: MoEngageSelfHandledCampaign) {
        guard let host else {
            log.e("Dropped — no host attached")
            return
        }

        let trigger = mapper.map(campaign)
        let campaignId = trigger.cepCampaignId
        cache.put(campaignId: campaignId, data: campaign)
        log.i("Received (cepId=\(campaignId))", campaign: trigger.campaignKey)

        let presentation = host.deliver(trigger)
        live[campaignId] = presentation

        _ = presentation.onSignal { [weak self] signal in
            guard let self else { return }
            switch signal {
            case .displayed: self.dispatcher.campaignShown(trigger)
            case .clicked:   self.dispatcher.campaignClicked(trigger)
            }
        }

        // A synchronous drop settled before any task could be scheduled. Free
        // the entry inline rather than across a suspension point.
        if let outcome = presentation.outcome.settledValue {
            finish(campaignId: campaignId, trigger: trigger, displayed: didDisplay(outcome))
            return
        }

        // `weak self`: PresentationPromise deliberately ignores cancellation, so
        // a task awaiting an outcome core never settles parks forever — it must
        // not keep the plugin alive.
        Task { @MainActor [weak self] in
            let outcome = await presentation.outcome.value
            self?.finish(campaignId: campaignId, trigger: trigger, displayed: didDisplay(outcome))
        }
    }

    /// The single terminal funnel. Idempotent through `live`, so the outcome
    /// task and `detach()` may both call it.
    private func finish(campaignId: String, trigger: CEPTriggerPayload, displayed: Bool) {
        guard live.removeValue(forKey: campaignId) != nil else { return }
        dispatcher.experienceEnded(trigger, displayed: displayed)
    }

    // MARK: - Pre-attach buffer

    private func bufferUntilAttach(_ campaign: MoEngageSelfHandledCampaign) {
        if buffered.count >= Self.maxBufferedCampaigns {
            let evicted = buffered.removeFirst()
            log.w("Pre-attach buffer full — dropping \(evicted.campaignId)")
        }
        buffered.append(campaign)
        log.d("No host attached yet — buffering \(campaign.campaignId)")

        let campaignId = campaign.campaignId
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachGrace) { [weak self] in
            MainActor.assumeIsolated { self?.expireBuffered(campaignId: campaignId) }
        }
    }

    private func expireBuffered(campaignId: String) {
        guard let index = buffered.firstIndex(where: { $0.campaignId == campaignId }) else { return }
        buffered.remove(at: index)
        log.w("No Digia plugin registered within \(Self.attachGrace)s of \(campaignId) — dropping it. Call Digia.register(MoEngagePlugin()) during startup.")
    }
}

/// `dismissed` is the only arm that means the experience reached the screen.
private func didDisplay(_ outcome: PresentationOutcome) -> Bool {
    if case .dismissed = outcome { return true }
    return false
}
