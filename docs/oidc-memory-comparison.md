# Browser OIDC memory investigation

Measured on 9 November 2026 with Ruby 4.0.9, using synthetic data, before replacing the browser client. These are historical exploratory measurements, not a production capacity guarantee. The application now uses `omniauth_oidc` with the issuer and redirect safeguards described below.

## Current strategy and lazy loading

Two local ARM64 Linux containers used the same Ruby version, Puma settings, mounted configuration, enabled browser OIDC and an anonymous homepage request. A settled `docker stats` sample showed the original image at 92.54 MiB and the lazy-loading image at 54.14 MiB, about 38 MiB less before the first login. Results include container memory and can vary between runs and hosts.

The first login attempt in the lazy container loaded the existing `omniauth_openid_connect` strategy and attempted discovery against a deliberately unreachable synthetic issuer. That attempt returned a generic failure in 0.23 seconds; it was not a successful login or a provider latency measurement. The next memory sample was 73.7 MiB. Ruby retains the loaded library until the process restarts, so the saving applies before the first browser login, not permanently after sign-in. The normal browser tests exercise successful login with a controlled provider.

## Alternative clients

The following exploratory measurements used separate macOS Ruby 4.0.9 processes, each after loading Sinatra, Sequel, SQLite and JWT. They compare RSS before and after `require` and garbage collection; the candidates were not integrated into the app or subjected to equivalent end-to-end security tests. Memory figures therefore describe library loading, not complete working authentication or Linux container usage.

| Library | Version | RSS before | RSS after | Increase |
| --- | --- | ---: | ---: | ---: |
| `omniauth_openid_connect` | 0.8.0 | 38.2 MiB | 66.9 MiB | 28.7 MiB |
| `omniauth_oidc` | 1.1.0 | 38.8 MiB | 42.6 MiB | 3.8 MiB |
| `oauth2` | 2.1.0 | 38.9 MiB | 46.9 MiB | 8.0 MiB |

The existing integration uses authorization code, state, nonce, S256 PKCE, a configured signing algorithm and issuer, expiry and session checks. It adds restrictions around callback parameters and stores only the verified subject. Its security regression suite covers these paths.

[`omniauth_oidc`](https://github.com/msuliq/omniauth_oidc) is actively maintained and documents state, nonce, PKCE and ID-token verification. It has a smaller dependency tree, but its 1.1.0 release derives its redirect URI from the request rather than accepting this application's fixed configured redirect URI. Its earlier implicit-flow authentication bypass was [fixed in 1.1.0](https://github.com/msuliq/omniauth_oidc/security/advisories/GHSA-xgh2-jgvm-8g78). Before replacing the current strategy, verify fixed issuer and redirect handling, error sanitisation, all existing regression tests, concurrent initialisation and a real Zitadel flow. The sample above is not proof of equivalent security.

[`oauth2`](https://github.com/ruby-oauth/oauth2/blob/main/OIDC.md) is maintained but documents that ID-token verification, nonce, PKCE and session/state handling are the application's responsibility. Adopting it would move security-sensitive OIDC logic into this application. Its lower library-load RSS does not include that implementation.

The application subsequently adopted `omniauth_oidc` while retaining lazy loading. Its regression suite exercises fixed issuer and redirect handling and token validation. Real Zitadel acceptance testing remains necessary before deployment.
