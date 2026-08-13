# quota-axi shared usage cache

Label: wayfinder:task (AFK)
Blocked by: none

## Question

Build quota-axi's shared on-disk single-flight usage cache so the whole host makes about one usage fetch per provider-account per TTL.

- Per provider+account record: payload, fetchedAt, Retry-After state.
- Single-flight locking: concurrent callers coalesce into one fetch.
- TTL about 5 minutes; on 429 serve the cache, honor Retry-After, else exponential backoff with jitter (15 minute default, matching jcode's current backoff).
- Every quota-axi invocation reads through the cache; JSON output carries a served-from-cache age marker per provider so consumers can age-degrade trust (fresh under about 10 minutes; aging shrinks assumed headroom; past about 1 hour the account is unknown per ADR 0031).
- Acceptance: two concurrent quota-axi calls produce one upstream fetch; a 429 never produces a retry storm; cache age is visible in `--json`.
