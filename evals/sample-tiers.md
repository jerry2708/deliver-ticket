# `/deliver-ticket` – sample tickets for classification evals

Ground truth for the v0.1 classification evals (plan section 12), agreed 2026-11-04 after an independent double rating (mine vs the coach's) and discussion of the disagreements. Criteria: plan section 6 (Risk, Size, Clarity, Type; final tier = highest).

Two checks per ticket:
- **Intake** – `go` (Definition of Ready met) or `stop (DoR)` (goal / testable AC / decision-maker missing → the skill must stop and draft questions, not invent ACs). `split` → the skill must propose separate tickets.
- **Tier** – for `stop (DoR)` rows, the tier expected once the missing goal/ACs are supplied.

| # | Ticket | Source | Intake | Tier | Reason | Missing DoR items |
|---|---|---|---|---|---|---|
| 1 | WL-01 – Save and unsave from the product card and detail view | `capstone/tickets.md` | go | C | creates a new authenticated per-user server API/store (IDOR risk: user id must come from the verified token); changed from B after discussion | – |
| 2 | WL-02 – Wishlist side panel and header entry | `capstone/tickets.md` | go | B | small feature | – |
| 3 | WL-03 – Add to cart from the wishlist panel | `capstone/tickets.md` | go | B | small feature | – |
| 4 | WL-04 – Assistant: save, remove and view the wishlist | `capstone/tickets.md` | go | C | AI agent changes saved wishlist/cart data on the user's behalf | – |
| 5 | WL-05 – Assistant: stock check and move wishlist items to the cart | `capstone/tickets.md` | go | C | AI agent changes saved wishlist/cart data on the user's behalf | – |
| 6 | WL-06 – Save button on products the assistant suggests | `capstone/tickets.md` | go | B | small feature | – |
| 7 | Retro #1 – `refresh()` drops a chat-made wishlist change while a toggle is pending | `day-15.md` retro | stop (DoR) | B | bug to fix | goal, testable AC, repro steps, expected vs actual |
| 8 | Retro #2 – Bulk wishlist→cart move uses a stale snapshot; `moveToCart` doesn't re-check membership | `day-15.md` retro | stop (DoR) | B | bug (concurrency) – bug is B minimum; changed from A after discussion | goal, testable AC, repro steps, expected vs actual |
| 9 | Retro #3 – Stock has two sources of truth (`inStock` vs `inventory`) | `day-15.md` retro | stop (DoR) | C | data migration – choosing one source of truth changes the data contract; changed from B after discussion | goal, testable AC (which source of truth is a decision) |
| 10 | Retro #4 – `GET /chat/threads?agentId` returns 500 for all 4 agents | `day-15.md` retro | stop (DoR) | C | per-user server API (thread list must be filtered by user) | goal, testable AC, expected vs actual |
| 11 | Retro #5 – `purchase-plan-card` crashes when the result has no `checkout` | `day-15.md` retro | stop (DoR) | B | bug to fix | goal, testable AC, repro steps, expected vs actual |
| 12 | Retro #6 – Rec-card "Added" stays after the cart changes elsewhere | `day-15.md` retro | stop (DoR) | B | bug to fix | goal, testable AC, repro steps, expected vs actual |
| 13 | Retro #7 – Prompt says `productId`, tool takes `productNameOrId` | `day-15.md` retro | stop (DoR) | C | prompt changes args passed to a side-effect tool (`moveWishlistItemToCartTool` writes the cart); changed from B on 2026-11-04 | goal, testable AC |
| 14 | Retro #8 – Process: `env-check` skill, `Stop` hook, `verify-report` skill | `day-15.md` retro | split | hook part C, skills B | three unrelated changes → separate tickets; hook/settings = infra config | – (split first; each part then checked on its own) |

## Re-run fixtures for `stop (DoR)` rows (ground truth, approved 2026-11-04)

Fixed goal/ACs I supply after the skill stops on the Definition of Ready, so every eval re-run classifies the same input. Decision-maker for all retro items: me (`day-15.md`, "owner: me"). Drafted by Claude from the one-line retro items and their evidence references; reviewed and approved by me on 2026-11-04 (missing DoR items column and fixtures).

| # | Ticket | Goal | ACs (Given/When/Then) |
|---|---|---|---|
| 7 | Retro #1 | A wishlist change made in the chat is never lost when a web save/unsave is still in progress. | AC1: Given a save toggle on product X is pending, when the assistant saves product Y and the wishlist refreshes, then after the toggle completes the wishlist holds both the toggle's result for X and Y. |
| 8 | Retro #2 | Moving the whole wishlist to the cart uses the wishlist as it is at move time. | AC1: Given a whole-wishlist move has started and item X is removed from the wishlist before it is moved, then X is not added to the cart. AC2: Given an item is no longer in the wishlist, when the move reaches it, then it is skipped and reported, and nothing else changes. |
| 9 | Retro #3 | Stock status has one source of truth. | AC1: In-stock status is derived from one field only; the other is removed or derived from it. AC2: Every product shows the same in-stock status as before the change (today 41/41 consistent). Open question (stays open for the eval): which field becomes the source of truth. |
| 10 | Retro #4 | Listing chat threads works for every agent. | AC1: Given a signed-in user, when the web app calls `GET /chat/threads?agentId=<id>` for each of the 4 agents, then the response is 200 with that user's threads for that agent. AC2: Another user's threads are never returned. |
| 11 | Retro #5 | The purchase-plan card never crashes on a valid result. | AC1: Given a purchase-plan result without `checkout`, when the card renders, then it shows the plan without the checkout section and no error. AC2: Given a result with `checkout`, the card renders as today. |
| 12 | Retro #6 | The recommendation card's "Added" state matches the current cart. | AC1: Given a recommended product shows "Added", when it is removed from the cart elsewhere (cart panel or chat), then the card no longer shows "Added". |
| 13 | Retro #7 | The agent's prompt describes the arguments the wishlist→cart tool really takes. | AC1: The prompt and the tool's parameter description agree (product id preferred, from the latest wishlist view; name allowed). AC2: Given two wishlist items with similar names, when I ask to move one of them by name, then exactly that item is moved, or the assistant asks which one. |

Bug repro steps are not in the fixtures on purpose – DoR item 4 doesn't stop intake; the re-run is expected to go on with an open question.
