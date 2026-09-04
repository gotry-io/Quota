<script lang="ts">
const THEME_STORAGE_KEY = "quota-theme";

type Theme = "light" | "dark";
type ThemePreference = "system" | Theme;

const options = ["system", "light", "dark"] as const satisfies readonly ThemePreference[];

let {
  id = "theme-toggle",
  menuPlacement = "up",
}: {
  id?: string;
  menuPlacement?: "up" | "down";
} = $props();

let menu = $state<HTMLDetailsElement | null>(null);
let preference = $state<ThemePreference>("system");

function storedPreference(): ThemePreference {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    return stored === "light" || stored === "dark" ? stored : "system";
  } catch {
    return "system";
  }
}

function resolvedTheme(value: ThemePreference): Theme {
  if (value !== "system") return value;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function label(value: ThemePreference): string {
  return value[0]?.toUpperCase() + value.slice(1);
}

function applyAppearance(value: ThemePreference): void {
  const theme = resolvedTheme(value);
  if (value === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = value;
  document
    .querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    ?.setAttribute("content", theme === "dark" ? "#111111" : "#f2f8f5");
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
  menu?.removeAttribute("open");
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

<details
  class="appearance-menu"
  class:appearance-menu-down={menuPlacement === "down"}
  bind:this={menu}
>
  <summary
    {id}
    class="theme-toggle"
    aria-label={`Appearance: ${label(preference)}`}
    title={`Appearance: ${label(preference)}`}
  >
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 3.5a8.5 8.5 0 0 1 0 17z" fill="currentColor" stroke="none" />
    </svg>
  </summary>
  <div class="appearance-options" role="group" aria-label="Appearance">
    {#each options as option}
      <button
        type="button"
        class:active={preference === option}
        aria-pressed={preference === option}
        onclick={() => choose(option)}
      >
        <span>{label(option)}</span>
        <span class="appearance-check" aria-hidden="true">{preference === option ? "✓" : ""}</span>
      </button>
    {/each}
  </div>
</details>
