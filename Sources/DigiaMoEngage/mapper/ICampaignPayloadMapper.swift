import DigiaEngage
/// Abstraction over the MoEngage → Digia payload translation step.
///
/// Isolates the mapping concern so that `MoEngagePlugin` is closed for
/// modification when the mapping logic changes. Provide a custom implementation
/// and inject it into `MoEngagePlugin` for testing or alternative strategies.
public protocol ICampaignPayloadMapper {
    /// Translates a MoEngage self-handled campaign into a Digia `CEPTriggerPayload`.
    func map(_ campaign: MoEngageSelfHandledCampaign) -> CEPTriggerPayload
}
