# Split of <ID> (size L, or bundled changes) - proposal, needs confirmation

| # | Part (ticket / MR) | Goal | ACs | Tier | Files (est.) | Depends on |
|---|---|---|---|---|---|---|
| 1 | <ID>-1 | | AC1, AC2 | | | - |
| 2 | <ID>-2 | | AC3 | | | <ID>-1 merged |

## AC table parent -> child
| Parent AC | Child | Notes |
|---|---|---|
| AC1 | <ID>-1 | |
| AC4 | out of scope | confirmed by <role> on <date> |

Check: every parent AC appears exactly once; none lost, none duplicated. Each part is deployable on its own and starts from the latest base (never from another part's branch).
