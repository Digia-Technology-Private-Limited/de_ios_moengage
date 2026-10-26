@testable import DigiaEngage
@testable import DigiaMoEngage
import Foundation
import Testing

/// The plugin pending buffer (de_workspace#71).
@MainActor
@Suite("MoEngagePlugin — pending buffer", .serialized)
struct MoEngagePendingBufferTests {
    private let client = FakeMoEngageClient()
    private let cache = CampaignCache()
    private let host: FakeCEPHost
    private let plugin: MoEngagePlugin

    init() {
        host = FakeCEPHost()
        host.isReady = false
        plugin = MoEngagePlugin(client: client, cache: cache)
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

    @Test("a campaign arriving after ready is delivered at once, never held")
    func postReadySkipsTheBuffer() {
        client.emit(FakeCampaign.modal(campaignId: "c-early"))
        host.isReady = true
        plugin.onHostReady()

        client.emit(FakeCampaign.modal(campaignId: "c-late"))

        #expect(
            host.delivered.map(\.cepCampaignId) == ["c-early", "c-late"],
            "the late campaign reaches Core at once, behind the flushed one"
        )

        plugin.onHostReady()
        #expect(host.delivered.count == 2, "nothing was held, so a second flush delivers nothing")
    }

    @Test("past the cap the oldest campaigns are lost and the newest twenty flush newest first")
    func capKeepsNewestTwenty() {
        for index in 1...25 { client.emit(FakeCampaign.modal(campaignId: "c-\(index)")) }

        host.isReady = true
        plugin.onHostReady()

        #expect(
            host.delivered.map(\.cepCampaignId) == (6...25).reversed().map { "c-\($0)" },
            "the oldest five are evicted, and the surviving twenty flush newest first"
        )
        #expect(client.dismissed.isEmpty, "a buffer drop never marks the campaign with MoEngage")
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
