<script lang="ts">
import { untrack } from "svelte";
import { setAccountStore, type AccountStore } from "$lib/account-store.svelte.ts";
import UsagePage from "./+page.svelte";

let { store }: { store: AccountStore } = $props();
setAccountStore(untrack(() => store));
</script>

<UsagePage />
