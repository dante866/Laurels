# Identity investigation (do this in-game on the main machine)

**Status:** paused M4 identity work pending real data. The rival layer currently
keys players by *name* (`UnitName` locally, `CHAT_MSG_ADDON` sender remotely). WoW-
Forever reportedly uses a two-name ("First Last"?) system, and we will NOT guess how
that flows through the APIs. Run the probe below, paste the output to Claude, decide,
then implement.

## Step 1 — run the probe

Log in on WoW-Forever with the addon installed and run:

```
/deed whoami
```

It prints (see `Diagnostics.lua`):
- `UnitName("player")` return #1 and #2 (name, realm)
- `GetUnitName(..., true/false)`, `UnitFullName(...)`
- `GetRealmName()`, `GetNormalizedRealmName()`
- `UnitGUID("player")` and each dash-separated GUID field
- **the critical one:** sends an addon message to yourself over YELL and reports the
  exact `sender` string `CHAT_MSG_ADDON` hands back, and whether `sender == UnitName`.

Copy all of it back to Claude.

## Step 2 — the decision tree

The three identity touchpoints in code:
- `Rival.lua` `MyName()` (line ~34) — local key + display label
- `Comm.lua` echo guard (line ~110) — `sender == UnitName("player")`
- `Rival.lua` `OnClaim` (line ~127) — remote key = `CHAT_MSG_ADDON` sender

Read the probe output:

- **`sender == UnitName` is YES, and the name is stable/unique** → name keying is
  safe as-is; the "First Last" format is just a string, no change needed beyond
  maybe displaying it nicely.
- **`sender == UnitName` is NO** → the echo guard is currently broken (you'd log
  yourself as a rival) and remote/local keys won't match. → **Must switch to GUID
  keying:** add a `guid` field to HELLO/CLAIM, key the ladder on GUID, compare GUIDs
  in the echo guard, and treat the name purely as a display label.
- **If the two names can both surface in different APIs** (e.g. account/OOC name vs
  character name) → GUID keying regardless, and decide which name to *show*.

## Step 3 — open product decisions (answer alongside the probe)

1. Which name should appear on the leaderboard (character "First Last", or an
   account/OOC name if one exists)?
2. Title held **per-character** or **per-player/account**? (Decides whether your alts
   compete with each other. Counts are currently per-character via
   `SavedVariablesPerCharacter`.) GUID is per-character; an account-level handle, if
   the two-name system exposes one, would be needed for per-account.

## Likely outcome

Most probable path is **GUID keying + display the character name**, per-character
identity. That's a contained change (protocol gains a `guid` field; swap the three
touchpoints) and also fixes the connected-realm name-suffix split noted after M3.
Do not implement until the probe confirms.
