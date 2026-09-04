import { agentDisplayName, BILLING_AGENTS } from "@gotry-io/quota-protocol";
import catalog from "../../../../packages/provider/catalog.json" with { type: "json" };

type ProviderCatalog = {
  providers: Array<{
    id: string;
    display_name: string;
    order: number;
    brand_icon_asset: string;
  }>;
};

const providers = (catalog as ProviderCatalog).providers
  .slice()
  .sort((left, right) => left.order - right.order);

const markById = new Map(providers.map((provider) => [provider.id, provider.brand_icon_asset]));

/** Catalog `display_name` values, in catalog order. Not a second name table. */
export const PROVIDER_DISPLAY_NAMES = providers.map((provider) => provider.display_name);

/** Usage agent names this build knows, from `BILLING_AGENTS`. */
export const AGENT_DISPLAY_NAMES = BILLING_AGENTS.map((agent) => agentDisplayName(agent));

/** Catalog `brand_icon_asset` as a `/providers/*.svg` URL, or null when the id is unknown. */
export function providerMarkSrc(providerId: string): string | null {
  const asset = markById.get(providerId);
  return asset === undefined ? null : `/providers/${asset}.svg`;
}
