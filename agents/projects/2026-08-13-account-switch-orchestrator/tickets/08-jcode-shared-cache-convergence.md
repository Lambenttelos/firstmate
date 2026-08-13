# jcode converge on shared usage cache

Label: wayfinder:task (AFK)
Blocked by: 01-quota-axi-shared-cache.md

## Question

Point jcode's Anthropic/OpenAI usage fetchers at quota-axi's shared on-disk cache (read-through, write-through) so N live sessions stop polling independently.

- Today: in-memory per-process cache, 300s TTL, 900s backoff on 429 (crates/jcode-base/src/usage.rs) - N sessions equals N pollers, the likely 429 source.
- Keep the in-memory layer as L1; the shared file is L2; preserve existing backoff semantics.
- Acceptance: with several live jcode sessions, upstream usage fetch rate is one per provider-account per TTL host-wide.
