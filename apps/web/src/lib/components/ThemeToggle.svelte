<script lang="ts">
const THEME_STORAGE_KEY = "quota-theme";

type Theme = "light" | "dark";

function preferredAppearance(): Theme {
  const stored = localStorage.getItem(THEME_STORAGE_KEY);
  if (stored === "light" || stored === "dark") return stored;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyAppearance(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
  document
    .querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    ?.setAttribute("content", theme === "dark" ? "#111111" : "#f2f8f5");
  document
    .querySelector<HTMLButtonElement>("#theme-toggle")
    ?.setAttribute("aria-label", theme === "dark" ? "Use light appearance" : "Use dark appearance");
}

function toggle(): void {
  const next = preferredAppearance() === "dark" ? "light" : "dark";
  localStorage.setItem(THEME_STORAGE_KEY, next);
  applyAppearance(next);
}

$effect(() => {
  applyAppearance(preferredAppearance());
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const onChange = (): void => {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (stored !== "light" && stored !== "dark") applyAppearance(preferredAppearance());
  };
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
});
</script>

<button
  id="theme-toggle"
  class="theme-toggle"
  type="button"
  aria-label="Use dark appearance"
  onclick={toggle}
>
  <svg class="icon-moon" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M15 3.5A8.5 8.5 0 1 1 4.5 15 7 7 0 0 0 15 3.5z" />
  </svg>
  <svg class="icon-sun" viewBox="0 0 24 24" aria-hidden="true">
    <circle cx="12" cy="12" r="4" />
    <path
      d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"
    />
  </svg>
</button>
