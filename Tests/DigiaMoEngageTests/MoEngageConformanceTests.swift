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

    init(host: FakeCEPHost = FakeCEPHost()) {
        self.client = FakeMoEngageClient()
        self.cache = CampaignCache()
        self.host = host
        self.plugin = MoEngagePlugin(client: client, cache: cache)
        plugin.attach(host: host)
    }

    /// Core's write face for the most recent delivery.
    var core: PresentationController { host.last }
}

/// The plugin conformance kit — spec §8.3.
///
/// One scenario table, run against all six plugin targets (Swift × 3,
/// Kotlin × 3). **The test names are the shared vocabulary**: `C4` means the
/// same thing in `ios/moengage` as it does in `android/clevertap`, so a row that
/// is green on five targets and red on one names the divergence by itself.
/// Never rename one without renaming all six.
///
/// "Release" needs a platform note here. MoEngage has no slot and no queue that
/// a missed call can stall, and no API to hand anything back — what it gives the
/// app is a **campaign object**, which the plugin must keep because every later
/// MoEngage call (`selfHandledShown`, `…Clicked`, `…Dismissed`) needs it back.
/// That cache entry is the held resource, so it is what these scenarios assert
/// on, alongside the marking calls that reached the fake client. Before v2 the
/// entry was freed only on a dismissal, which a dropped campaign never produces,
/// so every campaign Digia declined leaked an SDK object for the session.
@MainActor
@Suite("MoEngagePlugin — CEP conformance (spec §8.3)", .serialized)
struct MoEngageConformanceTests {

    @Test("C1 — deliver then dismissed: exactly one release, after the dismiss")
    func c1DismissedReleasesOnceAfterTheDismiss() async {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())

        h.core.markDisplaying()
        #expect(h.client.shown == ["camp_1"])
        #expect(h.cache.count == 1, "the entry is still held while it is on screen")
        #expect(h.client.dismissed.isEmpty)

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.cache.count == 0)
        #expect(h.client.dismissed == ["camp_1"])
        #expect(h.core.isHoldReleased, "G8: the hold cannot outlive the outcome")
    }

    @Test("C2 — deliver then dropped: exactly one release")
    func c2DroppedReleasesOnce() async {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())

        h.core.settle(.dropped(reason: .frequencyCapped, detail: nil))
        await drainMainActor()

        #expect(h.cache.count == 0, "a drop frees the entry exactly like a dismissal")
        #expect(h.client.dismissed.isEmpty, "nothing displayed, so nothing to dismiss")
        #expect(h.core.isHoldReleased)
    }

    @Test("C3 — outcome delayed, then cancel() from the CEP close: one release, idempotent")
    func c3CepCloseCancelsIdempotently() async {
        // platform note: MoEngage has no CEP-initiated close. Its self-handled
        // contract is one-way — the SDK hands a campaign over and never asks for
        // it back — so there is no plugin callback to drive this through, and the
        // scenario runs on the contract's own owner-initiated termination
        // instead. That is the same code path a CEP close reaches on the other
        // two plugins.
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        h.core.markDisplaying()

        h.core.presentation.cancel()
        await drainMainActor()

        #expect(h.cache.count == 0)
        #expect(h.client.dismissed == ["camp_1"])
        #expect(
            h.core.presentation.outcome.settledValue == .dismissed(reason: .cancelled, completed: false)
        )

        // G5: `cancel()` is idempotent and safe in any state, settled included.
        h.core.presentation.cancel()
        await drainMainActor()

        #expect(h.client.dismissed == ["camp_1"], "a repeated cancel must not double-release")
    }

    @Test("C4 — plugin unregistered mid-display still releases")
    func c4DetachMidDisplayStillReleases() async {
        // Asserted as a *fact*, not as a code path: after the unregister the
        // CEP's campaign object is no longer held, exactly once. That stays true
        // under both designs currently on the table — the iOS `detach()` backstop
        // that releases in-flight presentations, and the pure-G6 form where core
        // settling `plugin_detached` is the only thing that frees it. The two are
        // driven here in the order G6 specifies (settle, then detach) with no
        // drain in between, which is also the race between them.
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        h.core.markDisplaying()

        h.host.settleOwnedPresentations()
        h.plugin.detach()
        await drainMainActor()

        // Recorded while writing this, not fixed here: the iOS backstop calls
        // its terminal funnel with `displayed: false` regardless of what the
        // presentation actually did, so a campaign that *was* on screen loses
        // its final CEP marking when the backstop wins this race. The release
        // itself is never lost, which is why this row asserts the release. See
        // the N3 report.

        #expect(h.cache.count == 0, "unregistering must free the entry, and free it once")
        #expect(h.client.dismissed.count <= 1, "and must never mark the same campaign twice")
        #expect(
            h.core.presentation.outcome.settledValue
                == .dismissed(reason: .pluginDetached, completed: false)
        )
    }

    @Test("C5 — a throwing CEP release call is swallowed, with no crash and no lost release")
    func c5MisbehavingReleaseCall() async {
        // platform note: Swift cannot express the Kotlin twin's literal form.
        // `markDismissed(_:)` is non-throwing by type, an Obj-C exception out of
        // MoEngage is not catchable in Swift, and a Swift trap is fatal by design
        // — there is nothing to swallow. iOS is structurally safe for the half
        // the Kotlin fix addressed: `PresentationPromise.settle` resumes
        // continuations and the plugin code awaiting them runs on its own task,
        // so a plugin's completion handler never runs inside core's settle stack
        // and cannot unwind into it.
        //
        // What *is* expressible, and is asserted here, is the rest of the row:
        // the CEP's terminal call re-enters core from inside the release, and
        // neither the release nor the first outcome is lost.
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        h.core.markDisplaying()

        let core = h.core
        h.client.onMarkDismissed = { _ in
            core.presentation.cancel()
            core.settle(.dropped(reason: .error, detail: "re-entrant settle from the CEP"))
        }

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(h.client.dismissed == ["camp_1"])
        #expect(h.cache.count == 0, "the entry was freed despite the re-entrant call")
        #expect(
            core.presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false),
            "the first outcome stands — G1"
        )

        h.client.onMarkDismissed = nil
        h.client.emit(FakeCampaign.modal(campaignId: "camp_2"))
        #expect(h.host.delivered.count == 2, "the plugin was genuinely usable afterwards")
    }

    @Test("C6 — re-trigger the same campaignKey while the first is live: two presentations, two releases")
    func c6ReTriggerSameCampaignKey() async {
        // Two MoEngage campaigns pointing at one Digia campaign: same
        // `campaignKey` (the placementKey), different `cepCampaignId`. The plugin
        // keys its bookkeeping by campaign id, so the two must not collide — and
        // identity is `CampaignPresentation.id` regardless, which is what makes
        // the CleverTap form of this collision harmless too.
        let h = Harness()
        h.client.emit(FakeCampaign.modal(campaignId: "camp_a", placementKey: "promo"))
        h.client.emit(FakeCampaign.modal(campaignId: "camp_b", placementKey: "promo"))

        #expect(h.host.delivered.count == 2)
        #expect(h.host.delivered.map(\.campaignKey) == ["promo", "promo"])
        #expect(
            h.host.controllers[0].id != h.host.controllers[1].id,
            "two genuinely distinct presentations"
        )
        #expect(h.cache.count == 2)

        h.host.controllers[0].markDisplaying()
        h.host.controllers[0].settle(.dismissed(reason: .userClose, completed: false))
        h.host.controllers[1].settle(.dropped(reason: .surfaceBusy, detail: nil))
        await drainMainActor()

        #expect(h.cache.count == 0, "two presentations, two releases")
        #expect(h.client.dismissed == ["camp_a"], "only the one that displayed had a dismissal to report")
    }

    @Test("C7 — hold released early: one unblock, clicked still marked, final marking at outcome")
    func c7EarlyHoldRelease() async {
        let h = Harness()
        h.client.emit(FakeCampaign.modal())
        h.core.markDisplaying()

        h.core.releaseHold()
        await drainMainActor()

        // MoEngage has no hold to free early, so nothing binds here by design:
        // the campaign object is still needed for the marking calls below. The
        // unblock is the one at `outcome`.
        #expect(h.cache.count == 1)

        h.core.emitClicked(elementId: "primary_cta")
        #expect(h.client.clicked == ["camp_1"], "a click after the hold released is still marked")

        h.core.settle(.dismissed(reason: .screenExit, completed: true))
        await drainMainActor()

        #expect(h.cache.count == 0, "exactly one unblock, not one per phase")
        #expect(h.client.dismissed == ["camp_1"], "final marking at the outcome")
    }

    @Test("C8 — sync drop with the unblock bound after the fact still fires")
    func c8SyncDropLateAwaiter() async {
        // Regression guard for `PresentationPromise` collapsing back into a
        // fire-and-forget signal. The plugin's own path would survive that — it
        // peeks at the settled outcome before awaiting — so the late awaiter
        // below is the assertion that actually catches it.
        let h = Harness(host: FakeCEPHost(syncDrop: .unknownCampaignKey))

        h.client.emit(FakeCampaign.modal())

        #expect(h.host.delivered.count == 1, "Digia must actually have been asked")
        #expect(h.cache.count == 0, "released inline, with no turn of the main actor")
        #expect(h.core.isHoldReleased, "G8: the hold settled no later than the outcome")

        let fired = await awaiterAttachedLateFires(h.core.presentation.holdReleased)
        #expect(fired, "a late awaiter must still fire — a missed release wedges the CEP queue")
    }
}
