import { agentDisplayName, BILLING_AGENTS } from "@gotry-io/quota-protocol";
import catalog from "../../../../packages/provider/catalog.json" with { type: "json" };

type ProviderCatalog = {
  providers: Array<{ display_name: string; order: number }>;
};

const providers = (catalog as ProviderCatalog).providers
  .slice()
  .sort((left, right) => left.order - right.order);

/** Catalog `display_name` values, in catalog order. Not a second name table. */
export const PROVIDER_DISPLAY_NAMES = providers.map((provider) => provider.display_name);

/** Usage agent names this build knows, from `BILLING_AGENTS`. */
export const AGENT_DISPLAY_NAMES = BILLING_AGENTS.map((agent) => agentDisplayName(agent));
