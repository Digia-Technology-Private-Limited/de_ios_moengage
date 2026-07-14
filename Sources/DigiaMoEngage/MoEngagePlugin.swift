import DigiaEngage
import MoEngageCore
import MoEngageInApps
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
/// ## SOLID design
/// - **SRP** — mapping, caching, and event dispatch each live in their own type.
/// - **OCP** — inject custom `ICampaignCache` / `ICampaignPayloadMapper` without
///   modifying this class.
/// - **DIP** — depends on the `ICampaignCache` and `ICampaignPayloadMapper`
///   abstractions, not their concrete implementations.
@MainActor
public final class MoEngagePlugin: DigiaCEPPlugin {

    // MARK: - Public

    public let identifier = "moengage"

    // MARK: - Private

    private let cache: ICampaignCache
    private let mapper: ICampaignPayloadMapper
    private let dispatcher: MoEngageEventDispatcher
    private weak var delegate: DigiaCEPDelegate?

    private let logger = Logger(subsystem: "com.digia.moengage", category: "MoEngagePlugin")

    /// Obj-C bridge: `MoEngageInAppNativeDelegate` requires `NSObjectProtocol`.
    private lazy var inAppDelegate = MoEngageInAppDelegateAdapter(plugin: self)

    // MARK: - Init

    /// Creates a `MoEngagePlugin`.
    ///
    /// `cache` and `mapper` are optional — default implementations are used when
    /// omitted. Provide custom implementations for testing or alternative strategies.
    public init(
        cache: ICampaignCache = CampaignCache(),
        mapper: ICampaignPayloadMapper = CampaignPayloadMapper()
    ) {
        self.cache = cache
        self.mapper = mapper
        self.dispatcher = MoEngageEventDispatcher(cache: cache)
    }

    // MARK: - DigiaCEPPlugin

    public func setup(delegate: DigiaCEPDelegate) {
        self.delegate = delegate
        MoEngageSDKInApp.sharedInstance.setInAppDelegate(inAppDelegate)
        MoEngageSDKInApp.sharedInstance.getSelfHandledInApp(completionBlock: { [weak self] campaign, _ in
            guard let self, let campaign else { return }
            self.handleSelfHandledCampaign(campaign)
        })
        logger.info("\(self.identifier): setup complete — listening for self-handled in-app campaigns")
    }

    public func forwardScreen(_ name: String) {
        MoEngageSDKInApp.sharedInstance.setCurrentInAppContexts([name])
        MoEngageSDKInApp.sharedInstance.getSelfHandledInApp(completionBlock: { [weak self] campaign, _ in
            guard let self, let campaign else { return }
            self.handleSelfHandledCampaign(campaign)
        })
        logger.info("\(self.identifier): forwardScreen → \(name)")
    }

    public func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        guard payload.cepMetadata["campaignId"] != nil else {
            logger.warning("\(self.identifier): notifyEvent missing campaignId in cepMetadata")
            return
        }
        dispatcher.dispatch(event, payload: payload)
    }

    public func teardown() {
        delegate = nil
        cache.clear()
        logger.info("\(self.identifier): teardown complete")
    }

    public func healthCheck() -> DiagnosticReport {
        guard delegate != nil else {
            return DiagnosticReport(
                isHealthy: false,
                issue: "Plugin has no delegate — setup() has not been called.",
                resolution: "Call Digia.register(MoEngagePlugin()) before using the SDK."
            )
        }
        return DiagnosticReport(
            isHealthy: true,
            metadata: [
                "identifier":       identifier,
                "delegateSet":      "true",
                "cachedCampaigns":  "\(cache.count)",
                "cachedCampaignIds": cache.campaignIds.joined(separator: ","),
            ]
        )
    }

    // MARK: - Private helpers

    func handleSelfHandledCampaign(_ campaign: MoEngageInAppSelfHandledCampaign) {
        let payload = mapper.map(campaign)
        cache.put(campaignId: payload.cepCampaignId, data: campaign)
        logger.info("\(self.identifier): campaign ready — id=\(payload.cepCampaignId)")
        guard let delegate, delegate.onCampaignTriggered(payload) else {
            logger.info("\(self.identifier): campaign rejected — releasing id=\(payload.cepCampaignId)")
            MoEngageSDKInApp.sharedInstance.selfHandledDismissed(campaignInfo: campaign)
            cache.remove(campaignId: payload.cepCampaignId)
            return
        }
    }
}

// MARK: - MoEngageInAppNativeDelegate adapter

/// Bridges `MoEngageInAppNativeDelegate` (an Obj-C protocol requiring `NSObjectProtocol`)
/// to the `@MainActor` `MoEngagePlugin`.
private final class MoEngageInAppDelegateAdapter: NSObject, MoEngageInAppNativeDelegate {
    private weak var plugin: MoEngagePlugin?

    init(plugin: MoEngagePlugin) {
        self.plugin = plugin
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
        Task { @MainActor [weak self] in
            self?.plugin?.handleSelfHandledCampaign(inappCampaign)
        }
    }
}
