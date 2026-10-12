# Changelog

All notable changes to Digia Engage MoEngage (iOS) are documented in this file.

## [Unreleased]

### New Features

- MoEngage campaigns now carry runtime variables: the `variables` object (or `args`, the older spelling) in the self-handled campaign's JSON payload is passed to the Digia campaign for interpolation, whether stored as a JSON object or as JSON text, with numbers rendered as typed (`1` stays `1`, `5.0` renders as `5`) and arrays, objects, nulls and blanks skipped.
- The plugin can now be installed as the `DigiaMoEngage` CocoaPods pod, which depends on `DigiaEngage` `~> 4.0` and `MoEngage-iOS-SDK/InApps` 9.18 up to (not including) 11.0, so apps on the MoEngage 9.x and 10.x lines resolve a matching set of MoEngage modules; install MoEngage through `MoEngage-iOS-SDK` rather than its individual module pods, and note MoEngage 11 is not supported on CocoaPods yet.

### Improvements

- The Swift package now accepts MoEngage `apple-sdk >= 9.23.0, < 11.0.0`, matching the CocoaPods support window for tested MoEngage 10.x releases while continuing to reject the unverified 11.x linkage change.
- `MoEngagePlugin` now implements the redesigned `DigiaCEPPlugin` host contract (`attach(host:)`, `detach()`, `onScreenChanged(_:)`, `onHostReady()`, `onHostInitFailed()`) and requires `DigiaEngage` 4.0.0 or newer; `Digia.register(MoEngagePlugin())` is unchanged, but `identifier` is now `id`, the initializer takes a `MoEngageClient` (`init()` uses the real SDK) so `MoEngagePlugin(cache:mapper:)` no longer compiles, `setup(delegate:)`, `forwardScreen`, `notifyEvent` and `teardown` are removed, `ICampaignCache` and `ICampaignPayloadMapper` now use `MoEngageSelfHandledCampaign` and `CEPTriggerPayload` so custom implementations must be updated, `healthCheck()` reports `id`, `attached` and `livePresentations` instead of `identifier` and `delegateSet`, and `MoEngageClient`, `MoEngageSdkClient` and `MoEngageSelfHandledCampaign` are new public types.
- Campaigns now match by a campaign key read from the self-handled JSON payload (`digiaKey`, `digia_key`, `digia-key`, `campaignKey`, `campaign_key`, `campaign-key`, `digiaCampaign`, `digia_campaign`, `digia-campaign`, `digiaCampaignKey`, `digia_campaign_key` or `digia-campaign-key`); `placementKey`, `viewId`, `command` and `type` are no longer read, and a campaign with no key or an unparseable payload is dropped unless a Digia campaign is coupled to its MoEngage campaign ID, so add a key to existing campaigns.
- A campaign MoEngage offers while Digia is still initializing is now held (up to 20 campaigns for 5 minutes) and delivered once Digia is ready, and is discarded if Digia initialization fails or the plugin is unregistered; a campaign offered before the plugin is registered is dropped without telling MoEngage and is offered again when the plugin attaches.
- The minimum iOS version is lowered from 17 to 15, matching `DigiaEngage`.
- The Swift package now depends on MoEngage's `apple-sdk` repository from 9.23.0 instead of `MoEngage-iOS-SDK` from 9.18.0.

### Bug Fixes

- A campaign with `"type": "inline"` or no `type` is no longer reported to MoEngage as dismissed the moment it appears, so clicks on it are now reported; every campaign is reported dismissed only when it ends and only if it was displayed, and `type` no longer affects reporting.
- Campaigns Digia declines to show no longer stay in memory for the rest of the session; the MoEngage campaign object is released when the delivery settles, whether the campaign was shown or dropped.
- A campaign MoEngage offers again while its first copy is still on screen no longer loses a dismissal; each delivery is now tracked separately.
- Unregistering the plugin while a campaign is on screen now ends it, reports the dismissal to MoEngage and releases MoEngage's in-app delegate, and registering again reinstalls the delegate.
- Fixed a crash (`SIGTRAP` from a dispatch queue assertion) when MoEngage returned a self-handled campaign on a background queue.
