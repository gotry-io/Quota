<script lang="ts">
const THEME_STORAGE_KEY = "quota-theme";

type ThemePreference = "system" | "light" | "dark";

const options = ["system", "light", "dark"] as const satisfies readonly ThemePreference[];

let preference = $state<ThemePreference>("system");

function storedPreference(): ThemePreference {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    return stored === "light" || stored === "dark" ? stored : "system";
  } catch {
    return "system";
  }
}

function label(value: ThemePreference): string {
  return value[0]?.toUpperCase() + value.slice(1);
}

/** The browser chrome follows the page canvas, read back from the generated `--canvas`. */
function applyAppearance(value: ThemePreference): void {
  const root = document.documentElement;
  if (value === "system") delete root.dataset.theme;
  else root.dataset.theme = value;
  const canvas = getComputedStyle(root).backgroundColor;
  if (canvas) {
    document
      .querySelector<HTMLMetaElement>('meta[name="theme-color"]')
      ?.setAttribute("content", canvas);
  }
}

function choose(value: ThemePreference): void {
  preference = value;
  try {
    if (value === "system") localStorage.removeItem(THEME_STORAGE_KEY);
    else localStorage.setItem(THEME_STORAGE_KEY, value);
  } catch {
    // Private browsing and some test environments expose no storage.
  }
  applyAppearance(value);
}

$effect(() => {
  preference = storedPreference();
  applyAppearance(preference);
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const onChange = (): void => {
    if (preference === "system") applyAppearance("system");
  };
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
});
</script>

<div id="theme-toggle" class="seg" role="group" aria-label="Appearance">
  {#each options as option (option)}
    <button type="button" aria-pressed={preference === option} onclick={() => choose(option)}
      >{label(option)}</button
    >
  {/each}
</div>
