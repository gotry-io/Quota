import adapter from "@sveltejs/adapter-cloudflare";

/** @type {import("@sveltejs/kit").Config} */
const config = {
  kit: {
    adapter: adapter(),
    // Every document is rendered per request, so each one carries its own nonce and nothing has
    // to be hashed ahead of time: SvelteKit's bootstrap script embeds the page's own data and so
    // differs on every response, and the theme script in `app.html` claims the same nonce through
    // `%sveltekit.nonce%`. Styles keep `unsafe-inline` because Svelte injects the page's own
    // `<style>` blocks and a nonce on those buys nothing an attacker could not already reach.
    csp: {
      mode: "nonce",
      directives: {
        "default-src": ["self"],
        "script-src": ["self"],
        "style-src": ["self", "unsafe-inline"],
        "img-src": ["self", "data:"],
        "font-src": ["self"],
        "connect-src": ["self"],
        "frame-ancestors": ["none"],
        "base-uri": ["none"],
        "object-src": ["none"],
        "form-action": ["self"],
      },
    },
    prerender: {
      entries: [],
    },
  },
};

export default config;
