<script lang="ts">
let {
  message,
  onRetry,
  actionLabel = "Retry",
  id,
}: {
  message: string;
  onRetry?: (() => void) | undefined;
  /** What the one action does: "Retry" by default, "Sign in" when it starts sign-in. */
  actionLabel?: string;
  id?: string | undefined;
} = $props();
</script>

<div {id} class="notice retry-notice" role="alert">
  <p>{message}</p>
  {#if onRetry}
    <button class="text-button" type="button" onclick={onRetry}>{actionLabel}</button>
  {/if}
</div>
