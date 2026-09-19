/**
 * Preload for the restore-drill Node process. GitHub's token and profile
 * endpoints answer locally so the drill can open an Account over HTTP
 * without leaving the machine. Every other fetch is unchanged.
 */
const original = globalThis.fetch.bind(globalThis);

globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (url === "https://github.com/login/oauth/access_token") {
    return Response.json({ access_token: "gho_restore_drill", token_type: "bearer", scope: "" });
  }
  if (url === "https://api.github.com/user") {
    return Response.json({ id: 424242, login: "restore-drill", name: "Restore Drill" });
  }
  return original(input, init);
};
