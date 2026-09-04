<script lang="ts">
import { page } from "$app/state";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import SubscriptionDetail from "$lib/components/SubscriptionDetail.svelte";

const store = getAccountStore();
</script>

<SubscriptionDetail
  sel={page.params.sel ?? ""}
  summary={store.summary}
  loadError={store.loadError}
  subscriptionSelectors={store.subscriptionSelectors}
  now={store.now}
  onRetry={() => void store.refresh()}
/>
