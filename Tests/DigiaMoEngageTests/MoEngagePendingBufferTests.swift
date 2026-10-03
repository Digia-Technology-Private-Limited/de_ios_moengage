@testable import DigiaEngage
@testable import DigiaMoEngage
import Foundation
import Testing

/// The plugin pending buffer (de_workspace#71) on a fake clock.
@MainActor
@Suite("MoEngagePlugin — pending buffer", .serialized)
struct MoEngagePendingBufferTests {
    private let clock = FakeClock()
    private let client = FakeMoEngageClient()
    private let cache = CampaignCache()
    private let host: FakeCEPHost
    private let plugin: MoEngagePlugin

    init() {
        let clock = clock
        host = FakeCEPHost()
        host.isReady = false
        plugin = MoEngagePlugin(
            client: client,
            cache: cache,
            schedule: { clock.schedule($0, $1) },
            now: { clock.now }
        )
        plugin.attach(host: host)
    }

    private var keys: [String] { host.delivered.map(\.campaignKey) }

    @Test("held while Core is not READY, flushed newest first on ready")
    func flushNewestFirst() {
        client.emit(FakeCampaign.modal(campaignId: "c1", campaignKey: "k1"))
        client.emit(FakeCampaign.modal(campaignId: "c2", campaignKey: "k2"))
        #expect(host.delivered.isEmpty)

        host.isReady = true
        plugin.onHostReady()
        #expect(keys == ["k2", "k1"])
        #expect(cache.count == 2)
    }

    @Test("a re-pulled duplicate of a held campaign is skipped")
    func dedupHeld() {
        client.emit(FakeCampaign.modal(campaignId: "c1"))
        client.emit(FakeCampaign.modal(campaignId: "c1"))
        host.isReady = true
        plugin.onHostReady()
        #expect(host.delivered.count == 1)
    }

    @Test("a not_ready outcome puts the campaign back with no cache entry and no marking")
    func notReadyRebuffers() {
        host.isReady = true
        host.syncDrop = .notReady
        client.emit(FakeCampaign.modal(campaignId: "c1"))
        #expect(host.delivered.count == 1)
        #expect(cache.count == 0)
        #expect(client.dismissed.isEmpty)

        host.syncDrop = nil
        plugin.onHostReady()
        #expect(host.delivered.count == 2)
        #expect(cache.count == 1)
    }

    @Test("a held campaign expires after 5 minutes and is not delivered")
    func expires() {
        client.emit(FakeCampaign.modal(campaignId: "c1"))
        clock.advance(299)
        client.emit(FakeCampaign.modal(campaignId: "c2", campaignKey: "k2"))
        clock.advance(1)
        host.isReady = true
        plugin.onHostReady()
        #expect(keys == ["k2"])
    }

    @Test("FAILED drops held campaigns and later ones go straight to Core")
    func failedStopsBuffering() {
        client.emit(FakeCampaign.modal(campaignId: "c1"))
        plugin.onHostInitFailed()
        host.isReady = true
        plugin.onHostReady()
        #expect(host.delivered.isEmpty, "the dropped campaign never flushes")

        host.isReady = false
        plugin.onHostInitFailed()
        host.syncDrop = .initializationFailed
        client.emit(FakeCampaign.modal(campaignId: "c2"))
        #expect(host.delivered.count == 1)
        #expect(cache.count == 0)
    }

    @Test("detach drops held campaigns")
    func detachDrops() {
        client.emit(FakeCampaign.modal(campaignId: "c1"))
        plugin.detach()
        host.isReady = true
        plugin.attach(host: host)
        #expect(host.delivered.isEmpty)
    }
}
