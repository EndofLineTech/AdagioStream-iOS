# Audiobookshelf OpenID / SSO setup

AdagioStream can sign in to an Audiobookshelf server via OpenID Connect (SSO)
instead of a username and password. Audiobookshelf fronts the identity provider
(Google, Authentik, Authelia, …), so one PKCE authorization-code flow in the app
covers every backend. The app obtains the first `{accessToken, refreshToken}`
pair through SSO and then reuses the existing JWT refresh/rotation machinery —
SSO only changes how that first pair is obtained.

The app shows a **Sign in with SSO** button in *Add Account → Audiobookshelf*
only when the server reports `openid` in `GET /status`. It uses the server's
configured button label.

## Server-side setup the app cannot do

These must be configured on the server / identity provider. The app surfaces
them in-app under the SSO section's "SSO setup & requirements" disclosure.

1. **Allowed Mobile Redirect URIs** — in Audiobookshelf admin, add
   `adagiostream://oauth` to the OpenID setting *Allowed Mobile Redirect URIs*.
   This is the custom scheme `ASWebAuthenticationSession` captures.

2. **Identity-provider allow-list** — the IdP (Google/Authentik/Authelia) must
   allow-list the **Audiobookshelf HTTPS callback and mobile-redirect URIs**
   (e.g. `https://abs.example.com/auth/openid/callback` and the server's
   `/auth/openid/mobile-redirect`). It does **not** allow-list the
   `adagiostream://` scheme — the IdP only ever talks to Audiobookshelf over
   HTTPS; Audiobookshelf hands the code back to the app on the custom scheme.

3. **Reverse proxy `X-Forwarded-Proto`** — a proxy in front of Audiobookshelf
   must set `X-Forwarded-Proto: https` so the server builds correct HTTPS
   redirect URIs. Without it the IdP callback mismatches and sign-in fails.

4. **Server version** — Audiobookshelf **2.26.0 or newer** (matches the app's
   JWT + refresh-token-rotation requirement).

## Known limitation: self-signed certificates

`ASWebAuthenticationSession` (the OS-provided sign-in browser) will not proceed
against an **untrusted self-signed certificate** — it is an isolated system
browser and the app cannot install a trust exception for it. This is an OS
limitation, accepted by the product owner.

If your server uses a self-signed cert:

- Use a **trusted certificate** (e.g. Let's Encrypt), or
- **Sign in with a username and password** instead — password login has no such
  restriction and remains fully supported.

## Implementation pointers

- `AdagioStream/Services/AudiobookshelfOIDC.swift` — `GET /status` discovery.
- `AdagioStream/Services/AudiobookshelfOIDCFlow.swift` — PKCE (S256) and the
  `GET /auth/openid` → `GET /auth/openid/callback` exchange over one
  shared-cookie `URLSession` (the `auth_method` cookie must survive both calls).
- `AdagioStream/Views/Provider/AudiobookshelfOIDCSession.swift` — the iOS-only
  `ASWebAuthenticationSession` driver (tvOS excludes `Views/`).
- Token-only providers are `ProviderType.audiobookshelf` with empty
  username/password; tokens live in the Keychain, seeded via
  `AudiobookshelfAuth.seedTokens`.
