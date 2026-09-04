<script lang="ts">
import { page } from "$app/state";
import { getAccountDashboard } from "$lib/account-dashboard.svelte.ts";
import SubscriptionDetail from "$lib/components/SubscriptionDetail.svelte";

const dashboard = getAccountDashboard();
</script>

<SubscriptionDetail
  sel={page.params.sel ?? ""}
  summary={dashboard.summary}
  loadError={dashboard.loadError}
  subscriptionSelectors={dashboard.subscriptionSelectors}
  onRetry={() => void dashboard.loadSummary()}
/>
