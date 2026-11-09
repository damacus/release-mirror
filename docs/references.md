# Implementation references

The following primary sources informed the contract and implementation. Provider compatibility must still be verified against the intended installation.

- [Sinatra documentation](https://sinatrarb.com/intro.html): modular application, routes and runtime configuration; locked Sinatra 4.2.1.
- [Sequel database connections](https://sequel.jeremyevans.net/doc/opening_databases.html): SQLite connections, busy timeout and pool boundary; locked Sequel 5.110.0.
- [OmniAuth OpenID Connect](https://github.com/omniauth/omniauth_openid_connect): authorization-code flow, state, nonce and PKCE options; locked 0.8.0. The installed strategy source was inspected to reject caller nonce/verifier overrides and require an ID token.
- [ruby-jwt](https://github.com/jwt/ruby-jwt): explicit algorithm/issuer/audience/claim verification and trusted JWKS; locked 3.3.0.
- [Zitadel token introspection](https://zitadel.com/docs/guides/integrate/token-introspection): JWT and opaque access tokens, API-resource authentication options.
- [Forgejo workload OIDC](https://forgejo.org/docs/latest/user/actions/security-openid-connect/): workload issuer, token acquisition, immutable repository IDs and event restrictions. This is distinct from Forgejo human OAuth login.
- [Forgejo Actions reference](https://forgejo.org/docs/latest/user/actions/reference/): job OIDC enablement.
- [Distribution reference grammar](https://github.com/distribution/reference/blob/main/regexp.go): container name and tag syntax.
- [OCI image descriptor](https://github.com/opencontainers/image-spec/blob/main/descriptor.md) and [image index](https://github.com/opencontainers/image-spec/blob/main/image-index.md): content digests and platform fields.
- [Renovate custom datasource](https://docs.renovatebot.com/modules/datasource/custom/) and [regex manager](https://docs.renovatebot.com/modules/manager/regex/): public release JSON and current version/digest extraction. Behaviour additionally verified with Renovate 44.222.5's executable engine rather than inferred from schema support.
