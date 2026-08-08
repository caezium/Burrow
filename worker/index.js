// Serves the landing site, and permanently redirects the old hostname.
//
// burrow.henryzh.dev carried every inbound link the project has, so it 301s to
// burrow.computer path-for-path rather than being switched off. 301 (not 302)
// is what passes ranking signal to the new host; keep it that way.
const CANONICAL_HOST = "burrow.computer";
const LEGACY_HOSTS = new Set(["burrow.henryzh.dev", "www.burrow.computer"]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (LEGACY_HOSTS.has(url.hostname)) {
      url.hostname = CANONICAL_HOST;
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
