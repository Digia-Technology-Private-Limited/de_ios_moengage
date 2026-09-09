import DigiaEngage
import Foundation
import MoEngageInApps

/// Maps a MoEngage self-handled campaign to Digia Engage's CEP trigger contract.
public struct CampaignPayloadMapper: ICampaignPayloadMapper {
    private static let campaignKeyNames = [
        "digiaKey", "digia_key", "digia-key",
        "campaignKey", "campaign_key", "campaign-key",
        "digiaCampaign", "digia_campaign", "digia-campaign",
        "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
    ]

    public init() {}

    public func map(_ campaign: MoEngageInAppSelfHandledCampaign) -> CEPTriggerPayload {
        let campaignId = campaign.campaignId
        let payload = decodePayload(from: campaign)

        let type = stringValue(payload["type"]) ?? "inline"
        let metadata = [
            "campaignId": campaignId,
            "campaignName": campaign.campaignName,
            "type": type,
        ]

        return CEPTriggerPayload(
            cepCampaignId: campaignId,
            campaignKey: resolveCampaignKey(payload, fallback: campaignId),
            cepMetadata: metadata,
            variables: extractVariables(payload)
        )
    }

    private func decodePayload(
        from campaign: MoEngageInAppSelfHandledCampaign
    ) -> [String: Any] {
        guard
            let data = campaign.campaignContent.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return payload
    }

    private func resolveCampaignKey(_ payload: [String: Any], fallback: String) -> String {
        for key in Self.campaignKeyNames {
            if let value = stringValue(payload[key]) {
                return value
            }
        }
        return fallback
    }

    private func extractVariables(_ payload: [String: Any]) -> [String: String]? {
        var variables: [String: String] = [:]

        if let arguments = payload["variables"] as? [String: Any] ?? payload["args"] as? [String: Any] {
            for (key, value) in arguments {
                if let value = coerceToString(value) {
                    variables[key] = value
                }
            }
        } else {
            for (key, value) in payload {
                guard
                    !Self.campaignKeyNames.contains(key),
                    key != "type",
                    key != "args",
                    key != "variables",
                    let value = coerceToString(value)
                else {
                    continue
                }
                variables[key] = value
            }
        }

        return variables.isEmpty ? nil : variables
    }

    private func stringValue(_ rawValue: Any?) -> String? {
        guard
            let value = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func coerceToString(_ value: Any) -> String? {
        switch value {
        case let value as String:
            return value.isEmpty ? nil : value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}
