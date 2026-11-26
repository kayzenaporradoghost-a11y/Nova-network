export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/oauth/config") {
      // Client ID is public; fallback prevents a 503 if the Production variable is missing.
      const clientId = env.GITHUB_CLIENT_ID || "Ov23lilDdkErzbLiADMs";
      return json({ client_id: clientId });
    }

    if (request.method === "POST" && url.pathname === "/oauth/refresh") {
      const clientId = env.GITHUB_CLIENT_ID || "Ov23lilDdkErzbLiADMs";
      if (!env.GITHUB_CLIENT_SECRET) return json({ error: "oauth_not_configured" }, 503);
      let body;
      try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
      const refreshToken = typeof body.refresh_token === "string" ? body.refresh_token : "";
      if (!refreshToken || refreshToken.length > 4096) return json({ error: "invalid_refresh_token" }, 400);
      const refreshed = await fetch("https://github.com/login/oauth/access_token", {
        method: "POST",
        headers: { "Accept": "application/json", "Content-Type": "application/json", "User-Agent": "NETWORK-Android" },
        body: JSON.stringify({ client_id: clientId, client_secret: env.GITHUB_CLIENT_SECRET, grant_type: "refresh_token", refresh_token: refreshToken }),
      });
      const data = await refreshed.json().catch(() => ({}));
      if (!refreshed.ok || data.error || !data.access_token) return json({ error: "github_token_refresh_failed" }, 401);
      return json(data, 200, { "Cache-Control": "no-store" });
    }

    if (request.method !== "POST" || url.pathname !== "/oauth/exchange") {
      return json({ error: "not_found" }, 404);
    }
    const clientId = env.GITHUB_CLIENT_ID || "Ov23lilDdkErzbLiADMs";
    if (!env.GITHUB_CLIENT_SECRET) {
      return json({ error: "oauth_not_configured", missing: "GITHUB_CLIENT_SECRET" }, 503);
    }

    const length = Number(request.headers.get("content-length") || "0");
    if (length > 16384) return json({ error: "request_too_large" }, 413);

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    const code = typeof body.code === "string" ? body.code : "";
    const verifier = typeof body.code_verifier === "string" ? body.code_verifier : "";
    const redirectUri = typeof body.redirect_uri === "string" ? body.redirect_uri : "";
    // Accept only the native app's ephemeral IPv4 loopback callback.
    const match = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})\/callback$/.exec(redirectUri);
    const port = match ? Number(match[1]) : 0;
    if (!code || code.length > 2048 || !verifier || verifier.length < 43 || verifier.length > 128 ||
        !match || port < 1 || port > 65535) {
      return json({ error: "invalid_oauth_parameters" }, 400);
    }

    // No secrets, authorization codes, PKCE verifiers or tokens are logged or persisted.
    const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": "NETWORK-Android",
      },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: env.GITHUB_CLIENT_SECRET,
        code,
        redirect_uri: redirectUri,
        code_verifier: verifier,
      }),
    });

    const data = await tokenResponse.json().catch(() => ({}));
    if (!tokenResponse.ok || data.error || !data.access_token) {
      return json({
        error: "github_token_exchange_failed",
        error_description: data.error_description || data.error || "GitHub rejected the authorization code",
      }, 400);
    }
    return json(data, 200, { "Cache-Control": "no-store" });
  },
};

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...extraHeaders,
    },
  });
}
