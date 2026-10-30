# Design: Rival / Steal Layer (v3)

How a title held by one player gets contested and taken by another who does more
of the same deed. No game server is involved — this is peer-to-peer over WoW's
addon-message system, so everything here is **distributed and eventually consistent**.

## 1. Core model

- **Deed** — a definition (event + match + tiers). Already exists in v1/v2.
- **Claim** — "player P has count N on deed D (top tier T) as of time ts."
- **Ladder** — per deed, the set of claims this client has heard.
- **Holder** — per deed, the claim with the highest count. Computed identically on
  every client from the same claim set, so everyone agrees without a server.

The "steal" is emergent: whoever has the highest count *is* the holder. When your
broadcast count passes the current holder's, every client that hears it recomputes
and the title moves to you.

Holder resolution (deterministic tie-breaks, so all clients converge):
1. highest `count`
2. earliest `ts` to reach that count (rewards getting there first)
3. lowest `playerGUID` (final deterministic fallback)

## 2. The hard part: deed identity across players

Two players can only compete if they agree they're tracking **the same deed**. My
"Kobold Slaying" (match `nameContains="Kobold"`) and yours (match by `npcIDs`) are
*not* obviously the same thing. Three ways to handle it:

| Model | How a deed is matched across players | Pros | Cons |
|---|---|---|---|
| **(i) Auto-key** | `deedKey = hash(event + normalized match)`. Only *identical* definitions compete. | Zero setup; fully automatic. | Fragmented — trivial wording differences split the ladder. No "issue a challenge." |
| **(ii) Published deeds** | Author publishes a deed with a UUID; the definition travels with claims; others "adopt" it to compete. | Clean, intentional competition. **This is literally the "set a challenge for others" feature.** | Requires a publish/adopt step. |
| **(iii) Hybrid (recommended)** | Personal RP deeds stay local (auto-key, never broadcast). "Published" deeds carry a UUID + definition and are the only ones that compete. | Personal deeds stay private; competition is opt-in and unambiguous; unifies "challenge" + "steal." | Slightly more state (`published`, `uuid`, `origin`). |

**Recommendation: (iii).** It makes the steal mechanic and your "challenge others"
goal the *same* feature: publishing a deed = issuing a challenge; adopting it =
accepting; the ladder = the scoreboard.

## 3. Transport — **measured, not assumed**

WoW addon messages go over a chat channel via
`C_ChatInfo.SendAddonMessage(prefix, body, channel[, target])`, after
`C_ChatInfo.RegisterAddonMessagePrefix("DEEDK")`.

Which chat types carry addon messages is a **per-client fact, not a constant.**
Measured with `/deed commtest`, prefix registered successfully on both:

| Channel | WoW-Forever 1.60.1 (TOC 16001) | MoP Classic (TOC 50504) |
|---|---|---|
| `SAY` | **4** rejected | **0** delivered |
| `YELL` | **4** rejected | **0** delivered |
| `WHISPER` (to self) | 0 delivered | 0 delivered |
| custom `CHANNEL` | **0** delivered | **4** rejected |

`0` is success, non-zero a chat-type rejection. **The two clients are exact
mirror images**, which is why the broadcast channel is a setting
(`/deed channel`) with runtime fallback rather than a hardcoded value.

Consequences for design: on **MoP Classic the original proximity "nearby
rivals" mechanic is available** (`YELL` works). On **WoW-Forever it is not**,
and the ladder is necessarily server-wide over a custom channel. The same
addon therefore has a different competitive radius per client, and that is a
gameplay difference, not an implementation detail — so a fallback announces
itself in chat instead of switching silently.

On WoW-Forever specifically, every available option is membership-based rather
than distance-based:

| Channel | Reaches | Fits |
|---|---|---|
| `PARTY`/`RAID` | your group anywhere | group challenges |
| `GUILD` | whole guild anywhere | guild ladders (untested here — not in a guild) |
| custom hidden `CHANNEL` | everyone with the addon who joined it (server-wide) | **the ladder transport** |

**Decision: one shared hidden channel (`Deedkeeper`), joined on login.** The
ladder is server-wide. This is arguably a better fit for the actual goal —
publishing a deed is *issuing a challenge*, and a challenge shouldn't require
the challenger to be standing next to you.

Two implementation constraints learned the hard way:

- **Channel indices are per-session and shift** as the player joins and leaves
  other channels. Resolve via `GetChannelName` on every send; never cache.
- **`JoinTemporaryChannel` triggers the client's Code of Conduct notice** in
  chat on login. Harmless, but users will see it and it is not an addon bug.

If the nearby *flavour* is wanted back, it has to be done at the application
layer: put the zone in the CLAIM and filter the display to same-zone. That is
self-reported, but §5 already accepts self-reported counts, so it introduces
no new trust assumption.

Encoding & rate: payload is tiny and fixed, so a hand-rolled pipe-delimited
string (`2|TYPE|...`) beats pulling in AceSerializer. **But** a server-wide
channel means every client hears every claim, and the addon-message pipe has a
hard bandwidth cap — flooding it disconnects you. Throttling is therefore
mandatory, not optional. `Comm:InitTransport` queues sends and drains them at
`SEND_INTERVAL`, handing off to ChatThrottleLib wherever that global exists
(see §9.4 — it usually does, and the handoff has a subtlety). Broadcast on
tier change only — no chatty heartbeat.

## 4. Sync strategy

| Model | Behavior | Pros | Cons |
|---|---|---|---|
| **A. Broadcast-on-event** | emit a CLAIM when you earn/extend a tier, plus a throttled heartbeat while active | simple, timely | only reaches who's nearby *at that moment* |
| **B. Handshake-on-contact** | on hearing a HELLO, exchange claims for overlapping deeds | converges when players meet; low idle traffic | needs a request/response round |
| **C. Gossip relay** | rebroadcast others' claims you've heard | info spreads beyond direct contact | **amplifies spoofed claims**, loop control, complex |

**Recommendation: A + light B.** Broadcast on tier change (immediate) and a slow
heartbeat; send a HELLO on login/zone so nearby clients can ask for overlapping
claims. Defer C — the trust cost isn't worth it yet.

## 5. Trust / spoofing — be honest

There is no authority, so **counts are self-reported and cannot be fully verified.**
The saving grace: a client only ever increments *its own* count from *its own* combat
log — you can't inject a count into someone else's name, only inflate your own. So
cheating is self-defeating: you can fake "Kobold Slayer" but you've only lied to a
friendly RP community about kobolds. Mitigations, cheapest first:

1. **Social trust** (default) — it's an RP/flavor feature, not ranked PvP.
2. **Rate sanity cap** — ignore implausible deltas (e.g. +10k in 2s); cheap, add it.
3. Witnessed counting / server authority — out of scope, not worth it.

We ship 1 + 2 and say so plainly in the UI copy.

## 6. Protocol sketch

Prefix `DEEDK`. Body `2|TYPE|...` (proto bumped 1 → 2 to carry `guid`):
- `HELLO|ver|name|guid` — presence, on login.
- `CLAIM|deedKey|count|tier|name|ts|guid` — progress/holder update.
- `DEFPUB|uuid|ver|serialized-definition` — publish/adopt a deed definition (M4).
- `ASK|deedKey` — request claims for a deed (handshake).

`guid` is the identity for every purpose: ladder key, holder comparison, and
the self-echo check. `name` is a display label only — see §10. Carrying the
GUID in the payload also means nothing depends on the format of the
`CHAT_MSG_ADDON` `sender` string, which is client-specific.

All outbound sends are queued and rate-limited (§3).

## 7. Data model additions

- Deed gains: `published` (bool), `uuid` (string, if published), `origin` (author name).
- New store `DeedkeeperDB.ladder[deedKey] = { [guid] = {name, count, tier, ts} }`
  (account-wide cache of heard claims; your own entry sourced from the current char).
- `holders[deedKey]` is derived, not stored.

## 8. Build milestones (most are headlessly testable, like the engine)

- **M1 Comm bus** — register prefix, encode/decode, throttle, version gate. Pure
  logic around a swappable transport → unit-testable with a fake transport.
- **M2 Ladder + holder resolution** — pure logic, unit-testable (tie-breaks, steal
  detection). Like `tools/test_engine.lua`.
- **M3 Wire-up** — Engine tier events → CLAIM; receive → ladder update → steal events.
- **M4 Published deeds** — DEFPUB publish/adopt (the "challenge others" feature).
- **M5 UI** — holder + your rank in the panel; "you took / lost the title" toasts.

M1 and M2 are where the real correctness risk lives, and both can be fully tested
with LuaJIT before anything touches the game.

## 9. Decisions (resolved)

1. **Deed identity** — hybrid published-deeds (§2 iii). Publishing a deed *is*
   issuing a challenge. ✅
2. **Scope** — one shared server-wide channel. Not a choice in the end: `SAY`
   and `YELL` are refused by the client (§3), so there is no nearby option. ✅
3. **Trust** — social trust + rate cap (§5). ✅
4. **Throttling** — **not vendored, and deliberately so.** ✅ `Comm` queues and
   drains at a fixed interval, and hands off to **ChatThrottleLib** whenever
   that global exists. It usually does: CTL is embedded by many addons, and on
   Forever TRP3 ships v32 at `totalRP3/Libs/ChatThrottleLib/`, so Deedkeeper is
   already throttling through it there. Shipping a second copy would buy
   nothing — CTL version-checks and the newest wins regardless.

   The catch, and why this needed care: `ChatThrottleLib:SendAddonMessage`
   **returns nothing**, because it sends later. Channel negotiation (§3) reads
   the client's result code, so under CTL it saw `nil` on every send and never
   fell back — blind on exactly the clients most likely to have CTL loaded.
   The result now comes from CTL's `callbackFn(callbackArg, didSend,
   sendResult)` instead, through the same handler the direct path uses.

   Also note CTL **errors** on a body over 255 bytes rather than failing soft,
   which makes `Comm:Send`'s `MAX_BODY` check load-bearing, not just tidy.

5. **Per-character or per-account** — **per-character.** ✅ Your alts appear
   as separate rivals and can take a title off you. That is deliberate, not a
   limitation of GUID keying: whether an alt competes is the player's call,
   made by choosing whether to track the deed on that character at all. An
   account-level grouping would take that choice away, and GUIDs expose no
   account handle to build it from anyway.

Still open:

- **Zone filtering** — restore a "nearby" display filter (§3)? Cosmetic, and
  moot on MoP Classic where `YELL` is genuinely range-limited.

## 11. Testing without a second player

`/deed simrival <deedId> <count> <name>` fabricates a rival's claim and pushes
it through `Comm:HandleRaw` — the real receive path, not a shortcut into the
ladder. Decode, version gate, echo guard, `OnClaim`, ladder write, holder
recompute and the steal announcement all run exactly as they would for a
genuine remote claim.

The simulated clock advances in proportion to the jump, so a rival can be
moved by more than `Ladder.MAX_RATE` in one call. Without that the anti-spoof
cap would refuse any gain over 50/second and the tool could never set up a
steal worth watching. The cap is not weakened: a hand-built claim that jumps
instantly is still refused, and a test asserts it.

What this does **not** cover is the wire itself — whether one real client's
bytes reach another. `/deed commtest` covers that half: on MoP Classic a
`YELL` message was measured going out and coming back through the server.

## 10. Player identity — **measured on both clients**

The two clients disagree about what a character name *is*, and neither one
can be assumed from the other.

| | WoW-Forever | MoP Classic |
|---|---|---|
| `UnitName("player")` | `Indira`, `Resthaerl` | `Ija`, *(realm)* |
| 2nd return is really | a **surname** | a **realm** |
| `GetUnitName(p,false)` | `Indira Resthaerl` | `Ija` |
| `CHAT_MSG_ADDON` sender | `Indira Resthaerl` (space) | `Ija-Pagle` (hyphen) |

MoP Classic is ordinary WoW: `Name-Realm`, hyphenated, realm in the realm
slot. WoW-Forever is the odd one, with a surname occupying the realm slot.

**This is the case for GUID keying, not against it.** The same code is correct
on both without a branch: identity is the GUID, which is unambiguous
everywhere, and `GetUnitName("player", false)` happens to return the right
*display* string on each — the full two-part name on WoW-Forever, the bare
character name on MoP Classic. Had identity been keyed on names, each client
would have needed its own special case, and `sender` would have had to be
parsed differently (space vs hyphen) per client.

Known display limitation: on connected realms two players can share a
character name, and `name` in the payload carries no realm. They stay separate
ladder entries because GUIDs differ, but render with identical labels. Append
the realm from `sender` if that ever shows up in practice.

### 10.1 The WoW-Forever measurement in full

From `/deed whoami`:

```
UnitName("player")          = "Indira", "Resthaerl"
GetUnitName(player, false)  = "Indira Resthaerl"
GetUnitName(player, true)   = "Indira Resthaerl"
GetRealmName()              = "Classic Beta PvE"
UnitGUID("player")          = "Player-4618-00D1568C"
CHAT_MSG_ADDON sender       = "Indira Resthaerl"
```

`Resthaerl` is a **surname, not a realm** — the realm is `Classic Beta PvE`.
The surname occupies the slot where stock WoW puts the realm, and both
`GetUnitName` forms return the same string (stock WoW differs between them),
with a **space** separator rather than the `-Realm` suffix stock WoW uses.

Consequences, all of which were live bugs:

- `UnitName("player")` yields only `Indira`, so any other first-name-Indira
  character **collided into the same ladder entry**.
- `sender` (`Indira Resthaerl`) never equalled `UnitName` (`Indira`), so the
  self-echo guard never fired: a client **logged itself as its own rival**,
  appearing twice on its own leaderboard.

**Resolution: key on GUID everywhere, name is display-only.** `GetUnitName
("player", false)` is the only API returning the full name, so it is the
display label. Regression tests covering both failures live in
`tools/test_comm.lua` and `tools/test_rival.lua`.
