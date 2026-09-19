import DigiaEngage
import Foundation

/// Default implementation of `ICampaignPayloadMapper`.
///
/// Translates a MoEngage self-handled campaign into a Digia `CEPTriggerPayload` by:
/// - parsing the marketer-authored JSON from the campaign's self-handled content,
/// - using its `placementKey` (falling back to the campaign id) as `campaignKey` — the
///   slot/placement identifier CEPTriggerPayload uses to look up the Digia campaign config,
/// - flattening `type`/`viewId`/`command`/campaign metadata into `cepMetadata`, and
/// - flattening the marketer-authored `args` object into `variables`.
///
/// Parsing failures are gracefully degraded — an empty content map is used
/// so the campaign still reaches the rendering engine.
public struct CampaignPayloadMapper: ICampaignPayloadMapper {
    public init() {}

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

        let type         = stringValue(payloadMap["type"]) ?? "inline"
        let placementKey = stringValue(payloadMap["placementKey"])
        let viewId       = stringValue(payloadMap["viewId"])
        let command      = stringValue(payloadMap["command"])

        var cepMetadata: [String: String] = [
            "campaignId":   campaignId,
            "campaignName": campaignName,
            "type":         type,
        ]
        if let viewId { cepMetadata["viewId"] = viewId }
        if let command { cepMetadata["command"] = command }

        var variables: [String: String] = [:]
        if let value = payloadMap["args"], case let .object(obj) = value {
            for (key, jsonValue) in obj {
                if let s = flattenedString(jsonValue) {
                    variables[key] = s
                }
            }
        }

        return CEPTriggerPayload(
            cepCampaignId: campaignId,
            campaignKey: placementKey ?? campaignId,
            cepMetadata: cepMetadata,
            variables: variables.isEmpty ? nil : variables
        )
    }

    // MARK: - Private

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
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let arr as [Any]:
            return .array(arr.map { jsonValueFrom(any: $0) })
        case let obj as [String: Any]:
            return .object(obj.mapValues { jsonValueFrom(any: $0) })
        default:
            return .null
        }
    }
}
