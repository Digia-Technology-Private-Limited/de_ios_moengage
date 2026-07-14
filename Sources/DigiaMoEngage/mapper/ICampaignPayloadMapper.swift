import DigiaEngage
import MoEngageInApps

/// Abstraction over the MoEngage → Digia payload translation step.
///
/// Isolates the mapping concern so that `MoEngagePlugin` is closed for
/// modification when the mapping logic changes. Provide a custom implementation
/// and inject it into `MoEngagePlugin` for testing or alternative strategies.
public protocol ICampaignPayloadMapper {
    /// Translates a MoEngage campaign into Digia Engage's CEP trigger contract.
    func map(_ campaign: MoEngageInAppSelfHandledCampaign) -> CEPTriggerPayload
}
