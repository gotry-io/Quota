<script lang="ts">
import type { PublicProfile } from "@gotry-io/quota-protocol";
import { fetchPublicProfile } from "$lib/account-client";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import { formatCount, formatPublicCost, titleCase } from "$lib/format";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();
let profile = $state<PublicProfile | null>(null);
let error = $state<string | null>(null);

$effect(() => {
  void load(data.username);
});

async function load(username: string): Promise<void> {
  const result = await fetchPublicProfile(username);
  if (result.status === "missing") {
    error = "This profile is private or does not exist.";
    profile = null;
    return;
  }
  if (result.status === "error") {
    error = "Quota could not load this public profile.";
    profile = null;
    return;
  }
  error = null;
  profile = result.profile;
}
</script>

<section id="public-view" class="dashboard" aria-labelledby="public-title">
  <div class="dashboard-heading">
    <div>
      <p class="eyebrow">Public profile</p>
      <h1 id="public-title">Quota</h1>
    </div>
  </div>
  {#if error}
    <div id="public-error" class="notice" role="alert">{error}</div>
  {/if}
  {#if profile}
    <div id="public-body">
      <div class="summary-grid">
        <article
          ><span>Input tokens</span><strong id="public-input-total"
            >{formatCount(profile.usage.input_tokens)}</strong
          ></article
        >
        <article
          ><span>Output tokens</span><strong id="public-output-total"
            >{formatCount(profile.usage.output_tokens)}</strong
          ></article
        >
        <article
          ><span>API-equivalent cost</span><strong id="public-cost-total"
            >{formatPublicCost(profile.usage.cost_status, profile.usage.amount_microusd)}</strong
          ></article
        >
      </div>
      <section class="dashboard-section" aria-labelledby="public-quota-title">
        <div class="dashboard-section-heading">
          <div>
            <p class="eyebrow">Plan limits</p>
            <h2 id="public-quota-title">Quota</h2>
          </div>
        </div>
        <div id="public-quota-list" class="quota-grid">
          {#each profile.quota as provider (provider.provider)}
            <article class="quota-card">
              <div class="quota-card-heading">
                <div class="quota-card-identity">
                  <p class="quota-card-provider">{titleCase(provider.provider)}</p>
                  <p class="quota-card-account">{provider.plan ?? "Account"}</p>
                </div>
              </div>
              <QuotaWindows windows={provider.windows} provider={provider.provider} />
            </article>
          {/each}
        </div>
      </section>
      <section class="dashboard-section" aria-labelledby="public-models-title">
        <div class="dashboard-section-heading">
          <div>
            <p class="eyebrow">Usage</p>
            <h2 id="public-models-title">Models</h2>
          </div>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th scope="col">Model</th>
                <th scope="col">Tokens</th>
              </tr>
            </thead>
            <tbody id="public-model-breakdown">
              {#each profile.usage.models as model (model.name)}
                <tr>
                  <th scope="row">{model.name}</th>
                  <td>{formatCount(model.tokens)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  {/if}
</section>
