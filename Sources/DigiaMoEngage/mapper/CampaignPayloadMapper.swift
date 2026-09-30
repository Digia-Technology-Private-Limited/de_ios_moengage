import DigiaEngage
import Foundation

/// Default implementation of `ICampaignPayloadMapper`.
///
/// Translates a MoEngage self-handled campaign into a Digia `CEPTriggerPayload` by:
/// - parsing the marketer-authored JSON from the campaign's self-handled content,
/// - resolving `campaignKey` — the key core looks the Digia campaign up by — from that JSON,
/// - carrying the MoEngage identifiers in `cepMetadata`, and
/// - flattening the marketer-authored `variables` object into `variables`.
///
/// Parsing failures degrade to an empty content map, so the payload falls back
/// to the MoEngage campaign id — and core drops it as an unknown key unless a
/// campaign is actually coupled to that id.
public struct CampaignPayloadMapper: ICampaignPayloadMapper {
    public init() {}

    /// Accepted spellings of the campaign key in the marketer JSON, in priority order.
    ///
    /// Dashboard authors type this by hand, so every plausible casing and separator is
    /// accepted rather than silently dropping the campaign. Deliberately identical to
    /// `CleverTapPayloadMapper.campaignKeyNames` and to the Kotlin twin — a marketer who
    /// learned one spelling on one CEP must not have to relearn it on another.
    public static let campaignKeyNames = [
        "digiaKey", "digia_key", "digia-key",
        "campaignKey", "campaign_key", "campaign-key",
        "digiaCampaign", "digia_campaign", "digia-campaign",
        "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
    ]

    public func map(_ campaign: MoEngageSelfHandledCampaign) -> CEPTriggerPayload {
        let campaignId   = campaign.campaignId
        let campaignName = campaign.campaignName

        // The marketer-authored payload JSON lives in the self-handled content string.
        var payloadMap: [String: JSONValue] = [:]
        let jsonString = campaign.campaignContent
        if let data = jsonString.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in decoded {
                payloadMap[key] = jsonValueFrom(any: value)
            }
        }

        let cepMetadata: [String: String] = [
            "campaignId":   campaignId,
            "campaignName": campaignName,
        ]

        let variables = resolveVariables(payloadMap)

        return CEPTriggerPayload(
            cepCampaignId: campaignId,
            campaignKey: resolveCampaignKey(payloadMap) ?? campaignId,
            cepMetadata: cepMetadata,
            variables: variables
        )
    }

    // MARK: - Private

    /// Reads the Digia campaign key out of the marketer JSON, trying `campaignKeyNames` in
    /// priority order. Returns nil when the marketer typed no key at all.
    private func resolveCampaignKey(_ payloadMap: [String: JSONValue]) -> String? {
        for name in Self.campaignKeyNames {
            if let value = stringValue(payloadMap[name])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    /// Reads the runtime variables to interpolate into the campaign config.
    ///
    /// `args` is the older spelling, kept because campaigns authored against it are live; the
    /// Flutter plugin accepts the same pair. The first of the two that is actually an object
    /// wins — a marketer who wrote `variables` as something else gets the fallback rather than
    /// nothing, which is the only place this differs from Dart.
    private func resolveVariables(_ payloadMap: [String: JSONValue]) -> [String: String]? {
        var variables: [String: String] = [:]
        for name in ["variables", "args"] {
            guard let obj = asObject(payloadMap[name]) else { continue }
            for (key, jsonValue) in obj {
                if let value = flattenedString(jsonValue), !value.isEmpty {
                    variables[key] = value
                }
            }
            break
        }
        return variables.isEmpty ? nil : variables
    }

    /// An authored object, however the dashboard stored it: already parsed, or as JSON text.
    ///
    /// A marketer who pastes a variables blob into a string field gets an object all the same —
    /// accepting only a parsed object drops every variable on that campaign, silently. The
    /// WebEngage mappers take both for the same reason.
    private func asObject(_ value: JSONValue?) -> [String: JSONValue]? {
        switch value {
        case let .object(obj):
            return obj
        case let .string(text):
            guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                !decoded.isEmpty
            else { return nil }
            return decoded.mapValues { jsonValueFrom(any: $0) }
        default:
            return nil
        }
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let s) = value else { return nil }
        return s
    }

    /// Flattens a scalar `JSONValue` to a `String` for `variables`/`cepMetadata` (both
    /// `[String: String]`); arrays/objects/null have no flat representation and are dropped.
    private func flattenedString(_ value: JSONValue) -> String? {
        switch value {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .bool(b): return String(b)
        case .array, .object, .null: return nil
        }
    }

    /// Converts an `Any` value (from `JSONSerialization`) to `JSONValue`.
    private func jsonValueFrom(any value: Any) -> JSONValue {
        switch value {
        case let s as String:
            return .string(s)
        // Every JSON number arrives as an NSNumber, and an NSNumber bridges to `Bool` as
        // readily as to `Int` — `case let b as Bool` matches a plain `1` and would interpolate
        // an authored count as "true". Only the CFBoolean singletons are really booleans.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? .int(n.intValue) : .double(d)
        case let arr as [Any]:
            return .array(arr.map { jsonValueFrom(any: $0) })
        case let obj as [String: Any]:
            return .object(obj.mapValues { jsonValueFrom(any: $0) })
        default:
            return .null
        }
    }
}
