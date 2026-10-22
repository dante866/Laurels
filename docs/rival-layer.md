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

## 3. Transport

WoW addon messages go over a chat channel via
`C_ChatInfo.SendAddonMessage(prefix, body, channel[, target])`, after
`C_ChatInfo.RegisterAddonMessagePrefix("DEEDK")`. There is **no true "nearby"
channel** — proximity is approximated by range-limited chat channels.

| Channel | Reaches | Fits |
|---|---|---|
| `SAY` | ~40yd, same zone | very local |
| `YELL` | large radius / zone-ish, same faction | **"auto-broadcast nearby"** (your pick) |
| `PARTY`/`RAID` | your group anywhere | group challenges |
| `GUILD` | whole guild anywhere | guild ladders (easy add) |
| custom hidden `CHANNEL` | everyone with the addon who joined it (server-wide) | a future *global* ladder; spammy, not "nearby" |

**Recommendation:** `YELL` for the nearby broadcast (matches your earlier choice),
with `GUILD` as a cheap opt-in second scope. Defer the global channel.

Encoding & rate: payload is tiny and fixed, so a hand-rolled pipe-delimited string
(`v1|type|deedKey|count|tier|name|ts`) beats pulling in AceSerializer. **But** the
addon-message pipe has a hard bandwidth cap — flooding it disconnects you. We embed
**ChatThrottleLib** (tiny, battle-tested, used by most addons) for outbound sends.
Dependency tradeoff: hand-roll everything = fewer files but we'd reinvent throttling
badly; embedding one proven lib for the one genuinely hard part is the right call.

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

Prefix `DEEDK`. Body `v1|TYPE|...`:
- `HELLO|ver|name` — presence, on login/zone.
- `CLAIM|deedKey|count|tier|name|ts` — progress/holder update.
- `DEFPUB|uuid|ver|serialized-definition` — publish/adopt a deed definition.
- `ASK|deedKey` — request claims for a deed (handshake).

All outbound sends go through ChatThrottleLib at a low priority.

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

## 9. Open decisions (need your call)

1. **Deed identity** — go with hybrid published-deeds (§2 iii)? This couples "steal"
   and "challenge others" into one feature.
2. **Scope** — `YELL` nearby only for now, or also `GUILD` from the start?
3. **Trust** — ship social-trust + rate cap (§5) and move on? (recommended)
4. **Dependency** — OK to embed ChatThrottleLib (one small vendored lib) for send
   throttling?
