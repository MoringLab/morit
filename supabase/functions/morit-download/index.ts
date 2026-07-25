import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// The previous arbitrary-URL proxy was disabled because forwarding user URLs
// safely requires egress controls, DNS pinning, timeouts, and per-user quotas.
// Keep JWT verification enabled in the deployment configuration as defense in
// depth, even though this version never fetches an upstream URL.
Deno.serve(() =>
  new Response(
    JSON.stringify({
      code: "proxy_disabled",
      message: "Proxy downloads are temporarily disabled for security.",
    }),
    {
      status: 410,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
      },
    },
  )
);
