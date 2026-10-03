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

    // MARK: - Private

    private let client: MoEngageClient
    private let cache: ICampaignCache
    private let mapper: ICampaignPayloadMapper
    private let dispatcher: MoEngageEventDispatcher

    private var host: DigiaCEPHost?

    /// Presentations this plugin still owns, keyed by presentation id.
    ///
    /// The core-minted id, not the campaign id: the campaign id repeats
    /// across deliveries, and sharing an entry would steal a dismissal.
    /// Also the idempotency guard on the terminal path: `finish` removes the
    /// entry first, so the outcome task and `detach()` can race and only the
    /// first one does any work.
    private var live: [String: CampaignPresentation] = [:]

    private let log = DigiaLogger("ME")

    /// Campaigns held while Core is not READY (de_workspace#71). A drop needs no
    /// MoEngage call: the campaign was never marked, so it stays eligible.
    private let pending: PendingPayloadBuffer<MoEngageSelfHandledCampaign>

    /// Set by ``onHostInitFailed()``: deliver directly so Core drops at once.
    private var hostFailed = false

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
        mapper: ICampaignPayloadMapper = CampaignPayloadMapper(),
        schedule: @escaping PendingPayloadBuffer<MoEngageSelfHandledCampaign>.Scheduler = PendingPayloadBuffer<MoEngageSelfHandledCampaign>.mainQueueScheduler,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.cache = cache
        self.mapper = mapper
        self.dispatcher = MoEngageEventDispatcher(client: client, cache: cache)
        let log = DigiaLogger("ME")
        self.pending = PendingPayloadBuffer(now: now, schedule: schedule) { campaign, reason in
            log.w(
                "Dropping held \(campaign.campaignId) (\(reason.wire))",
                campaign: mapper.map(campaign).campaignKey,
                stage: .trigger,
                reason: reason
            )
        }

        installListener()
    }

    // MARK: - DigiaCEPPlugin

    public func attach(host: DigiaCEPHost) {
        guard self.host == nil else { return }
        self.host = host
        installListener()
        if host.isReady { flushPending() }

        // The re-pull stays: a campaign MoEngage offers again is deduplicated by campaign id.
        client.fetchSelfHandledInApp()
        log.i("Plugin attached — listening for self-handled in-app campaigns")
    }

    public func onScreenChanged(_ screenName: String) {
        client.setCurrentContexts([screenName])
        client.fetchSelfHandledInApp()
        log.d("Screen tracked (screen=\(screenName))")
    }

    public func onHostReady() {
        hostFailed = false
        flushPending()
    }

    public func onHostInitFailed() {
        hostFailed = true
        pending.dropAll(DropReason.initializationFailed)
    }

    public func detach() {
        pending.dropAll(DropReason.pluginDetached)
        hostFailed = false
        // Core settles a plugin's presentations before detaching it, but the
        // tasks awaiting those outcomes have not necessarily run yet. This is
        // the last moment the plugin can free MoEngage's side and its own cache.
        for (key, presentation) in live {   // a snapshot: `finish` mutates `live`
            // Read the outcome rather than assuming `false`: `cancel()` settles on the main
            // actor, inline, so by now the true terminal result is here. If core had already
            // settled this presentation as `dismissed` and only its awaiting task had yet to
            // run, hardcoding `false` silently dropped the final CEP marking for a campaign
            // the user really did see.
            presentation.cancel()
            finish(
                key: key,
                trigger: presentation.trigger,
                displayed: presentation.outcome.settledValue.map(didDisplay) ?? false
            )
        }
        live.removeAll()

        client.setSelfHandledListener(nil)
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

    /// Installs the self-handled listener: at construction so it is ready before
    /// attach, and on every attach so a re-register after detach hears campaigns
    /// again. A campaign that arrives before Core is READY is held (de_workspace#71).
    private func installListener() {
        client.setSelfHandledListener { [weak self] campaign in
            self?.onCampaignTriggered(campaign)
        }
    }

    func onCampaignTriggered(_ campaign: MoEngageSelfHandledCampaign) {
        guard !isHeldOrLive(campaign.campaignId) else {
            log.d("Skipping \(campaign.campaignId) — already held or live")
            return
        }
        guard let host, host.isReady || hostFailed else {
            pending.add(campaign)
            return
        }
        deliver(campaign, to: host)
    }

    private func isHeldOrLive(_ campaignId: String) -> Bool {
        pending.contains { $0.campaignId == campaignId }
            || live.keys.contains { cache.get(campaignId: $0)?.campaignId == campaignId }
    }

    private func flushPending() {
        guard let host else { return }
        for campaign in pending.drain() { deliver(campaign, to: host) }
    }

    /// Hands a campaign to Digia and binds MoEngage's side to the handle.
    ///
    /// Shown and clicked ride `onSignal`; the dismissal and the cache entry ride
    /// `outcome`. Nothing rides `holdReleased` — MoEngage has no hold to free
    /// early (spec §7.3).
    private func deliver(_ campaign: MoEngageSelfHandledCampaign, to host: DigiaCEPHost) {
        let trigger = mapper.map(campaign)
        let presentation = host.deliver(trigger)
        if presentation.outcome.settledValue?.isHostNotReady == true {
            pending.add(campaign)
            return
        }
        // Keyed by presentation id — see `live`.
        let key = presentation.id
        cache.put(campaignId: key, data: campaign)
        log.i("Received (cepId=\(trigger.cepCampaignId))", campaign: trigger.campaignKey)
        live[key] = presentation

        _ = presentation.onSignal { [weak self] signal in
            guard let self else { return }
            switch signal {
            case .displayed: self.dispatcher.campaignShown(key: key, campaignKey: trigger.campaignKey)
            case .clicked:   self.dispatcher.campaignClicked(key: key, campaignKey: trigger.campaignKey)
            }
        }

        // A synchronous drop settled before any task could be scheduled. Free
        // the entry inline rather than across a suspension point.
        if let outcome = presentation.outcome.settledValue {
            finish(key: key, trigger: trigger, displayed: didDisplay(outcome))
            return
        }

        // `weak self`: PresentationPromise deliberately ignores cancellation, so
        // a task awaiting an outcome core never settles parks forever — it must
        // not keep the plugin alive.
        Task { @MainActor [weak self] in
            let outcome = await presentation.outcome.value
            self?.finish(key: key, trigger: trigger, displayed: didDisplay(outcome))
        }
    }

    /// The single terminal funnel. Idempotent through `live`, so the outcome
    /// task and `detach()` may both call it.
    private func finish(key: String, trigger: CEPTriggerPayload, displayed: Bool) {
        guard live.removeValue(forKey: key) != nil else { return }
        dispatcher.experienceEnded(key: key, campaignKey: trigger.campaignKey, cepId: trigger.cepCampaignId, displayed: displayed)
    }
}

/// `dismissed` is the only arm that means the experience reached the screen.
private func didDisplay(_ outcome: PresentationOutcome) -> Bool {
    if case .dismissed = outcome { return true }
    return false
}
