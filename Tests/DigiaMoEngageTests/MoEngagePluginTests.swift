@testable import DigiaEngage
@testable import DigiaMoEngage
import Foundation
import Testing

@MainActor
private final class Harness {
    let client: FakeMoEngageClient
    let cache: CampaignCache
    let host: FakeCEPHost
    let plugin: MoEngagePlugin

    init(host: FakeCEPHost = FakeCEPHost(), attach: Bool = true) {
        self.client = FakeMoEngageClient()
        self.cache = CampaignCache()
        self.host = host
        self.plugin = MoEngagePlugin(client: client, cache: cache)
        if attach { plugin.attach(host: host) }
    }

    var core: PresentationController { host.last }
}

/// Lifecycle tests for MoEngage's cached campaign entry.
///
/// MoEngage has no slot and no queue a missed call can stall. What it has is a
/// campaign object the plugin must keep, because every later MoEngage call needs
/// it back — so the question every test here asks is **was the entry freed?**
/// It used to be freed only on a dismissal, which a dropped campaign never
/// produces; binding it to `outcome` is what closes that leak. The second
/// question is whether the marking calls were honest, which is what the injected
/// client makes assertable at all.
@MainActor
@Suite("MoEngagePlugin — cache entry lifecycle", .serialized)
struct MoEngagePluginTests {

    // MARK: - The cache entry: freed on both arms, always

    @Test("frees the cache entry when the experience is dismissed")
    func freesEntryOnDismiss() async {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        #expect(h.cache.count == 1)

        h.core.markDisplaying()
        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.cache.count == 0)
        #expect(h.client.dismissed == ["camp_1"])
    }

    @Test("frees the cache entry when the campaign is dropped")
    func freesEntryOnDrop() async {
        // The leak this commit closes: a dropped campaign produced no dismissal,
        // so its entry — a MoEngage SDK object — lived for the whole session.
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        #expect(h.cache.count == 1)

        h.core.settle(.dropped(reason: .frequencyCapped, detail: nil))
        await drainMainActor()

        #expect(h.cache.count == 0)
        #expect(h.client.dismissed.isEmpty, "nothing displayed, so nothing to dismiss")
    }

    @Test("a synchronous drop frees the entry without waiting for a task")
    func syncDropFreesEntryInline() {
        // No `await` anywhere: deliver() returns already settled.
        let h = Harness(host: FakeCEPHost(syncDrop: .unknownCampaignKey))

        h.client.emit(FakeCampaign.modal())

        #expect(h.host.delivered.count == 1, "Digia must actually have been asked")
        #expect(h.cache.count == 0)
    }

    @Test("detach frees the entry for a live presentation")
    func detachFreesEntry() {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        h.core.markDisplaying()

        h.plugin.detach()

        #expect(h.cache.count == 0)
        #expect(h.core.isSettled)
        #expect(h.client.listenerCleared)
    }

    @Test("two live deliveries of one campaign settle independently")
    func repeatedCampaignSettlesIndependently() async {
        // Keyed by presentation id: the second delivery must not steal the
        // first one's entry, and each dismissal must reach MoEngage.
        let h = Harness()
        h.client.emit(FakeCampaign.modal(campaignId: "camp_1"))
        h.client.emit(FakeCampaign.modal(campaignId: "camp_1"))
        #expect(h.host.controllers.count == 2)

        h.host.controllers[0].markDisplaying()
        h.host.controllers[0].settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()
        h.host.controllers[1].markDisplaying()
        h.host.controllers[1].settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.client.dismissed == ["camp_1", "camp_1"])
        #expect(h.cache.count == 0)
    }

    // MARK: - Marking: what actually reached MoEngage

    @Test("a displayed campaign is reported shown, then dismissed")
    func reportsShownThenDismissed() async {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())

        h.core.markDisplaying()
        #expect(h.client.shown == ["camp_1"])
        #expect(h.client.dismissed.isEmpty, "still on screen")

        h.core.settle(.dismissed(reason: .ctaAction, completed: true))
        await drainMainActor()

        #expect(h.client.dismissed == ["camp_1"])
    }

    @Test("a click is reported to MoEngage")
    func reportsClick() {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())

        h.core.markDisplaying()
        h.core.emitClicked(elementId: "primary_cta")

        #expect(h.client.clicked == ["camp_1"])
    }

    @Test("a campaign stays open until its presentation settles")
    func dismissalWaitsForTheOutcome() async {
        let h = Harness()
        h.client.emit(FakeCampaign.inline())

        h.core.markDisplaying()
        #expect(h.client.shown == ["camp_inline"])
        // `"type":"inline"` once bought this campaign an early dismissal. Digia has no such
        // concept, and marking a campaign dismissed while it is on screen told MoEngage
        // something untrue — the outcome is the only thing that ends a campaign now.
        #expect(h.client.dismissed.isEmpty, "still on screen — nothing to dismiss yet")

        h.core.settle(.dismissed(reason: .screenExit, completed: true))
        await drainMainActor()

        #expect(h.client.dismissed == ["camp_inline"])
        #expect(h.cache.count == 0, "the entry dies with the presentation")
    }

    // MARK: - Pre-attach drops, never buffered (de_workspace#42)

    @Test("a campaign triggered before attach drops silently and re-pulls on attach")
    func preAttachDropsAndRePullsOnAttach() {
        let h = Harness(attach: false)

        h.client.emit(FakeCampaign.modal())
        #expect(h.host.delivered.isEmpty)
        #expect(h.client.shown.isEmpty)
        #expect(h.client.clicked.isEmpty)
        #expect(h.client.dismissed.isEmpty, "never displayed, so nothing to dismiss")
        #expect(h.cache.count == 0)

        h.plugin.attach(host: h.host)

        #expect(h.host.delivered.isEmpty, "a pre-attach drop is never delivered late")
        #expect(h.client.fetchCount == 1, "attach re-pulls instead of flushing")
    }

    @Test("every pre-attach drop stays silent, so nothing is lost to a marking call")
    func preAttachDropsStaySilent() {
        let h = Harness(attach: false)

        for index in 1...6 { h.client.emit(FakeCampaign.modal(campaignId: "camp_\(index)")) }

        #expect(h.host.delivered.isEmpty)
        #expect(h.client.shown.isEmpty)
        #expect(h.client.clicked.isEmpty)
        #expect(h.client.dismissed.isEmpty)
        #expect(h.cache.count == 0)

        h.plugin.attach(host: h.host)

        #expect(h.host.delivered.isEmpty, "nothing was buffered, so nothing flushes")
        #expect(h.client.fetchCount == 1, "the drop frees the campaign to come back on the re-pull")
    }

    // MARK: - Wiring

    @Test("a screen change sets the MoEngage context and asks for a campaign")
    func screenChangeSetsContext() {
        let h = Harness()
        let fetchesBefore = h.client.fetchCount

        h.plugin.onScreenChanged("Checkout")

        #expect(h.client.contexts.last == ["Checkout"])
        #expect(h.client.fetchCount == fetchesBefore + 1)
    }

    @Test("health reports live presentations and clears after detach")
    func healthReportsLivePresentations() {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())

        let live = h.plugin.healthCheck()
        #expect(live.isHealthy)
        #expect(live.metadata["livePresentations"] == "1")
        #expect(live.metadata["cachedCampaigns"] == "1")

        h.plugin.detach()
        #expect(!h.plugin.healthCheck().isHealthy)
    }

    @Test("attach is idempotent")
    func attachIsIdempotent() {
        let h = Harness()

        h.plugin.attach(host: h.host)
        h.client.emit(FakeCampaign.modal())

        #expect(h.host.delivered.count == 1, "a second attach must not double-deliver")
    }

    @Test("detach drops the delegate and a re-register installs a fresh one")
    func detachResetsDelegateAndReAttachReinstalls() {
        // After detach MoEngage must no longer reach the plugin, and the next
        // register must hear campaigns again — not stay deaf on a cleared listener.
        let h = Harness()
        h.plugin.detach()
        #expect(!h.client.hasListener, "detach must drop the listener")

        h.client.emit(FakeCampaign.modal(campaignId: "stale"))
        #expect(h.host.delivered.isEmpty, "a post-detach callback reaches nothing")
        #expect(h.client.shown.isEmpty && h.client.dismissed.isEmpty, "no mark without a delivery")
        #expect(h.cache.count == 0)

        h.plugin.attach(host: h.host)
        h.client.emit(FakeCampaign.modal(campaignId: "fresh"))
        #expect(
            h.host.delivered.map(\.cepCampaignId) == ["fresh"],
            "a re-register installs a fresh delegate"
        )
    }

    @Test("attach keeps the init-time adapter when one exists")
    func attachKeepsInitAdapter() {
        // Replacing the adapter on attach frees the one a fetch already
        // captured, losing a launch campaign. Attach must not reinstall.
        let client = FakeMoEngageClient()
        let plugin = MoEngagePlugin(client: client)
        plugin.attach(host: FakeCEPHost())

        #expect(client.installCount == 1, "init installs once, attach keeps it")
    }

    @Test("a launch campaign buffered before attach survives it")
    func bufferedCampaignSurvivesAttach() {
        let client = FakeMoEngageClient()
        let host = FakeCEPHost()
        let plugin = MoEngagePlugin(client: client)

        client.emit(FakeCampaign.modal(campaignId: "launch"))
        plugin.attach(host: host)

        #expect(host.delivered.map(\.cepCampaignId) == ["launch"])
    }
}
