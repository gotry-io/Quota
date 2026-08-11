//! Provider quota collectors.
//!
//! Collectors deliberately return normalized, redacted snapshots. Credentials and provider-owned
//! response bodies never cross this module's result boundary.

pub mod claude;
pub mod codex;
pub mod common;
pub mod deepseek;
pub mod grok;
pub mod kimi;
pub mod litellm;
pub mod openrouter;

pub use common::{CollectionContext, ProviderError, ProviderSession, QuotaSnapshot};

use crate::catalog::ProviderId;

pub fn discover(provider: ProviderId, context: &CollectionContext) -> Vec<ProviderSession> {
    match provider {
        ProviderId::Codex => codex::discover(context),
        ProviderId::Claude => claude::discover(context),
        ProviderId::Grok => grok::discover(context),
        ProviderId::OpenRouter => openrouter::discover(context),
        ProviderId::DeepSeek => deepseek::discover(context),
        ProviderId::Kimi => kimi::discover(context),
        ProviderId::LiteLlm => litellm::discover(context),
    }
}

pub fn collect(
    provider: ProviderId,
    session: &ProviderSession,
    context: &CollectionContext,
) -> Result<QuotaSnapshot, ProviderError> {
    match provider {
        ProviderId::Codex => codex::collect(session, context),
        ProviderId::Claude => claude::collect(session, context),
        ProviderId::Grok => grok::collect(session, context),
        ProviderId::OpenRouter => openrouter::collect(session, context),
        ProviderId::DeepSeek => deepseek::collect(session, context),
        ProviderId::Kimi => kimi::collect(session, context),
        ProviderId::LiteLlm => litellm::collect(session, context),
    }
}
