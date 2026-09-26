<script lang="ts">
import { untrack } from "svelte";
import { setAccountStore, type AccountStore } from "$lib/account-store.svelte.ts";
import HomePage from "./+page.svelte";

let { store }: { store: AccountStore } = $props();
setAccountStore(untrack(() => store));
</script>

<HomePage />
