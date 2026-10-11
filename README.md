# DigiaMoEngage iOS

A [Digia Engage](https://github.com/Digia-Technology-Private-Limited/de_ios_core) plugin that routes MoEngage self-handled in-app campaigns into the Digia rendering engine. Enables MoEngage campaigns to render Digia-powered UI experiences.

## Requirements

| | Minimum |
|---|---|
| iOS | 15.0 |
| DigiaEngage | 4.0.0 |
| MoEngage (Swift Package Manager) | `apple-sdk >= 9.23.0, < 11.0.0` |
| MoEngage (CocoaPods) | `MoEngage-iOS-SDK >= 9.18.0, < 11.0.0` |

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Digia-Technology-Private-Limited/de_ios_moengage.git",
        from: "2.0.0"
    ),
]
```

Then add `DigiaMoEngage` as a target dependency:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "DigiaMoEngage", package: "de_ios_moengage"),
    ]
)
```

Or add it directly in Xcode via **File → Add Package Dependencies** and enter the repository URL.

### CocoaPods

```ruby
pod 'MoEngage-iOS-SDK/InApps', '10.14.0' # any release from 9.18 up to 11.0
pod 'DigiaMoEngage', '~> 2.0'
```

Install MoEngage through its `MoEngage-iOS-SDK` pod, as above, rather than pinning individual module pods such as `MoEngageCore` or `MoEngageInApps`. `MoEngage-iOS-SDK` pins one matching version of every MoEngage module. MoEngage's module pods do not limit each other's versions, so pinning them separately can end in a `pod install` version conflict or a build error in `MoEngageMessaging`.

The pod depends on `DigiaEngage` (`~> 4.0`) and `MoEngage-iOS-SDK/InApps` (9.18 up to 11.0), which brings in `MoEngageCore` and `MoEngageInApps` at matching versions. It does not bundle any of them. MoEngage 11 is not supported on CocoaPods yet.

## Usage

### 1. Initialize MoEngage

Initialize the MoEngage SDK the way you normally do, before registering the plugin.

### 2. Initialize Digia Engage and register the plugin

```swift
import DigiaEngage
import DigiaMoEngage

try await Digia.initialize(DigiaConfig(apiKey: "YOUR_DIGIA_API_KEY"))
Digia.register(MoEngagePlugin())
```

A campaign MoEngage offers while Digia is still initializing is held (up to 20 campaigns, for 5 minutes) and delivered once Digia is ready.

### 3. Create a self-handled in-app campaign in MoEngage

Create a **Self-Handled In-App** campaign and put a JSON payload in its content. The payload names the Digia campaign to show, and can carry runtime variables:

```json
{
  "digiaKey": "welcome_offer",
  "variables": { "name": "Asha", "discount": 20 }
}
```

- **Campaign key.** The key is read from the first of these fields that is present: `digiaKey`, `digia_key`, `digia-key`, `campaignKey`, `campaign_key`, `campaign-key`, `digiaCampaign`, `digia_campaign`, `digia-campaign`, `digiaCampaignKey`, `digia_campaign_key`, `digia-campaign-key`. A campaign with no key, or with a payload that is not valid JSON, is dropped, unless a Digia campaign is coupled to its MoEngage campaign ID.
- **Variables.** `variables` (or `args`, the older spelling) is passed to the Digia campaign for interpolation. It can be a JSON object or JSON text. Numbers render as typed (`1` stays `1`, `5.0` renders as `5`); arrays, objects, nulls and blank values are skipped.
- **Contexts.** The plugin sets MoEngage's current in-app context to the screen name Digia is told about, so any contexts you set on a MoEngage campaign must match your Digia screen names.

Impressions, clicks and dismissals are reported back to MoEngage by the plugin.

## License

Distributed under the Business Source License 1.1 (BUSL-1.1).

---

Built with ❤️ by the [Digia](https://digia.tech) team
