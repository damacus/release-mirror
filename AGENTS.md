# Release Mirror

This repository is public. Use only synthetic fixtures and examples. Never copy proprietary source, actual private registry names/repository paths, credentials, complete identity token payloads or raw build events into files or diagnostics.

Read the current OpenSpec change before implementing. Keep application work here; infrastructure and live identity configuration are separate tasks. Preserve actual upstream tags exactly: no invented versions, build numbers, release classes, retention schemes or generated moving aliases.

Use Ruby 3.4.9. `mise run test` runs the behavioural suite. `mise run serve` starts the application using `CONFIG_FILE` (default `config/local.json`). See README for isolated HTTP/Renovate/container contracts. Never point destructive contract fixtures at production.

No production deployments, live identity changes or merges without explicit authorisation. Check git identity before committing. Do not add local environment paths, tokens or test logs to published evidence.
