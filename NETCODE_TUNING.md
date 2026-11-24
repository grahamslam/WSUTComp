# WSUTComp Netcode Tuning Guide

Reference for server admins on every netcode-adjacent setting in WSUTComp, what it does, and what to change when specific symptoms appear.

All mutator settings live in `WSUTComp.ini` under `[WSUTComp.MutUTComp]`, and all of them can be set live via WebAdmin (Settings → Rules → UTComp NewNet / UTComp Movement). Engine settings live in `UT2004.ini`.

---

## Quick baseline (competitive dedicated server)

```ini
; UT2004.ini  [IpDrv.TcpNetDriver]
NetServerMaxTickRate=100
LanServerMaxTickRate=100
MaxClientRate=100000
MaxInternetClientRate=100000

; WSUTComp.ini  [WSUTComp.MutUTComp]
; --- NewNet ---
bEnableEnhancedNetcode=True
NewNetUpdateFrequency=200
PingTweenTime=0.5
PawnCollisionHistoryLength=0.35
PawnCollisionMaxRewind=0.240
MaxPing=0.150

; --- Correction smoothing (visual) ---
bEnableCorrectionSmoothing=True
CorrectionHalfLife=0.020
CorrectionJumpThreshold=60.0
MaxVisualOffset=400.0
bSmoothCameraOffset=True

; --- Movement prediction ---
bKeepMomentumOnLanding=True
NetMoveDelta=0.011
MaxSavedMoves=250
MaxResponseTime=0.125
bMoveErrorAccumFix=True
MoveErrorAccumFixValue=0.009
bCoalesceMoves=True
ClientErrorThreshold=25.0
```

If you're CPU-constrained, drop `NetServerMaxTickRate` to `85`. Everything else stays the same.

---

## Setting reference

### Engine (UT2004.ini → `[IpDrv.TcpNetDriver]`)

| Setting | Default | Recommended | What it does |
|---|---|---|---|
| `NetServerMaxTickRate` | 20 | **100** (85 on weak hardware) | Server physics + replication tick rate. Above 120 the engine's float-precision timing starts to wobble on long matches. At 100 tick, PawnCollisionCopy stores 35 history samples per 350 ms window — worst-case rewind error ~8.8 UU at full dodge speed (pawn collision radius is 25 UU, so rewind is not tick-limited). |
| `LanServerMaxTickRate` | 35 | match NetServerMaxTickRate | Same, for LAN games. |
| `MaxClientRate` | 10000 | **100000** | Per-client bandwidth ceiling (bytes/sec). This caps what `NetSpeed` any connecting client can negotiate up to. **Do not leave at 10000** — see the 10001 threshold note below. |
| `MaxInternetClientRate` | 10000 | **100000** | Same as above, applied to internet (non-LAN) connections. |
| `KeepAliveTime` | 0.2 | 0.2 (leave default) | Seconds between heartbeat packets to an otherwise-idle connection. Keeps NAT port bindings alive, feeds ACK regularity, and pairs with `ConnectionTimeout=20.0` for dead-connection detection. **Does not affect fluidity during active play** — combat traffic runs at 50–100+ Hz, far above this floor. See the note below before adjusting. |
| `ConnectionTimeout` | 20.0 | 20.0 | Seconds of silence before the engine drops a connection as dead. Leave alone unless you have a specific reason. |

**⚠ The 10001 NetSpeed threshold**

UT2004's engine has a hardcoded NetSpeed tier break at exactly `10000`. Clients at `NetSpeed <= 10000` use the slower-cadence movement RPC path (smaller `MoveRepSize`, capped ServerMove rate). Clients at `NetSpeed >= 10001` unlock the higher-bandwidth path — more frequent position updates, better movement precision, smoother visible play.

If your server's `MaxClientRate` is set to exactly `10000`, **every client is clamped to the low-bandwidth tier** regardless of what they've configured locally, and movement will feel sluggish / stuttery even on otherwise-good connections.

Set the server cap generously (`100000` is a sensible ceiling for modern connections) and let clients pick their own `NetSpeed` in UT2004.ini's `[Engine.Player]` section. Competitive players typically use values like `10001`, `20000`, or `25001` — values just above tier thresholds to ensure they land in the higher tier.

**⚠ Cargo-cult warning: do not lower `KeepAliveTime` for "smoother play"**

Community folklore sometimes suggests setting `KeepAliveTime=0.1` or `0.05` for a smoother feel. This is not real — the setting only fires when no other outgoing packet has gone to the client in that window, which during combat is never (actor state replicates at 50+ Hz, orders of magnitude faster than the 5 Hz heartbeat floor at the default of 0.2). Lowering it just adds heartbeat packets to already-idle connections for no gain.

If you genuinely need to tune:
- **Raise to 0.5** only if you're on very bandwidth-constrained infrastructure and want to trim idle-connection overhead. Cost: slower dead-connection detection.
- **Lower below 0.2**: never a good reason. Skip it.

### NewNet core (WSUTComp.ini → `[WSUTComp.MutUTComp]`)

| Setting | Default | What it does |
|---|---|---|
| `bEnableEnhancedNetcode` | True | Master toggle for lag compensation. If False, no rewind; hitscan uses server-current position. |
| `NewNetUpdateFrequency` | 200 | `NetUpdateFrequency` applied to `NewNet_PRI`. Higher = faster ping update replication. |
| `PingTweenTime` | 0.5 | How often the client sends a Ping RPC to the server (seconds). Lower = more responsive ping tracking, more bandwidth. 0.5 s gives ~2.5 s window convergence with the 5-sample median filter. |
| `PawnCollisionHistoryLength` | 0.35 | How long each `PawnCollisionCopy` retains position history (seconds). Must be ≥ max expected rewind. |
| `PawnCollisionMaxRewind` | 0.240 | Hard cap on how far back `TimeTravelPawn` will interpolate. Clamps rewind even if `PingDT` is higher. |
| `MaxPing` | 0.150 | **(WSUTComp fork)** Most rewind a shot gets (seconds, plus a ~25 ms + 2 ticks margin). Each shot is also capped at the round trip the **server** measures for that player, so a client can't claim more lag than it has. Players with real ping above this get clamped — their shots under-rewind by the excess, they need to lead. Also caps the client's own ping estimate for fake projectile timing. `PawnCollisionMaxRewind` stays the absolute ceiling. |

### Correction smoothing (visual, ModernPawn)

Makes server-triggered position snaps render smoothly via `PrePivot` offset decay instead of a hard jump.

| Setting | Default | What it does |
|---|---|---|
| `bEnableCorrectionSmoothing` | True | Master toggle for the visual smoother. |
| `CorrectionHalfLife` | 0.020 | Exponential decay half-life (seconds) of the visual offset. 20 ms half-life → full visual recovery in ~130 ms. Lower = snappier, higher = smoother-but-laggier. |
| `CorrectionJumpThreshold` | 60.0 | Minimum frame-to-frame position delta (UU) that counts as a "correction" and triggers smoothing. Normal dodge at 880 UU/s at 60 fps = 14.7 UU/frame → well under 60, not smoothed. Rocket knockback = above → treated as correction. |
| `MaxVisualOffset` | 400.0 | Jumps larger than this (UU) are treated as teleports and not smoothed. |
| `bSmoothCameraOffset` | True | Also offset first-person camera to match the mesh, so the local player doesn't see their own viewpoint snap during a correction. |

### Movement prediction / correction accumulator

Controls client-side prediction queueing and the server-side drift-correction threshold.

| Setting | Default | What it does |
|---|---|---|
| `bKeepMomentumOnLanding` | True | UTComp-style gliding: landing doesn't clear horizontal momentum. Competitive-standard on. |
| `NetMoveDelta` | 0.011 | Target spacing (seconds) between `ServerMove` RPCs from client. 0.011 s ≈ 91 Hz send rate. |
| `MaxSavedMoves` | 250 | Client-side cap on the SavedMove prediction queue. With `bCoalesceMoves=True` this almost never fills; without it, high-fps clients hit it. |
| `MaxResponseTime` | 0.125 | Maximum DeltaTime per saved move (seconds). Caps how much input one SavedMove can represent. |
| `bMoveErrorAccumFix` | False | If True, use `MoveErrorAccumFixValue` as the recheck interval instead of the legacy `180/NetSpeed` formula. Recommended True for tighter drift tracking. |
| `MoveErrorAccumFixValue` | 0.009 | Recheck interval (seconds) for server-side client-position error when `bMoveErrorAccumFix=True`. |
| `bCoalesceMoves` | False | **(WSUTComp fork)** Xonotic-style input coalescing. When True, multiple render frames between network ticks share one `SavedMove`. Prevents the "Exceeded max saved moves" overflow at 1000+ fps. **Recommended True.** |
| `ClientErrorThreshold` | 25.0 | **(WSUTComp fork)** Squared-UU distance between server-computed and client-reported position before the server forces a `LongClientAdjustPosition`. 25 = VSize 5 UU tolerance. Original UTComp hardcoded 3 (1.73 UU) which was too tight under float precision. |

---

## Workload profiles

The Quick Baseline is a reasonable middle ground. These profiles tune it for specific server shapes. Only the values that differ from baseline are listed; everything else stays at its baseline default.

### Profile A — Small-team high-FPS competitive (4v4, 240–480 FPS)

**Shape**: 4v4 or smaller, same-region competitive community, clients running 240–480+ FPS, typical ping 30–80 ms.

```ini
; UT2004.ini  [IpDrv.TcpNetDriver]
NetServerMaxTickRate=100          ; 120 acceptable at 8-player load if matches are short

; WSUTComp.ini  [WSUTComp.MutUTComp]
bCoalesceMoves=True               ; MANDATORY — without it, queue overflows in under 1s at 480 FPS
bMoveErrorAccumFix=True
MaxPing=0.150                     ; lower to 0.100 if everyone is sub-80ms
ClientErrorThreshold=25.0         ; try 16 after baseline testing — high-FPS clients drift less
```

**Watch for**: at 480 FPS, frame-time variance occasionally falls outside the coalesce window, spawning a new SavedMove with sub-millisecond Delta. Benign, but visible as log noise if `bDebugLogging=True`.

**Don't bother with**: raising `MaxSavedMoves` past 250 — with coalesce on, queue depth stays at 1–3 entries regardless of client FPS.

### Profile B — Mid-size public (5v5 to 8v8, mixed FPS/ping)

**Shape**: 10–16 player pub, mixed client hardware (60 to 300 FPS), mixed ping (40–180 ms), varied skill.

```ini
; UT2004.ini
NetServerMaxTickRate=100

; WSUTComp.ini
bCoalesceMoves=True               ; still recommended — protects the 300 FPS players
bMoveErrorAccumFix=True
MaxPing=0.150                     ; keep default — covers the common range
PawnCollisionMaxRewind=0.240      ; keep default
ClientErrorThreshold=25.0
```

**Watch for**: Some pub players will have inconsistent ping (cellular tethering, WiFi). The 5-sample median filter handles spikes, but route changes take ~2.5 s to propagate. If someone swaps networks mid-match, expect a brief window of rewind desync.

**Consider**: if you have a core group of regulars with stable low ping but occasional high-ping drop-ins, lean toward `MaxPing=0.120` — it favors the regulars.

### Profile C — Large public / ONS (12–16 players, CPU-sensitive)

**Shape**: 12–16 players, possibly on older or shared hardware, Onslaught or large-map team modes, varied clients.

```ini
; UT2004.ini
NetServerMaxTickRate=85           ; lower if you see server hitches under full load
MaxClientRate=100000              ; NOT 10000 — that clamps clients to slow engine tier

; WSUTComp.ini
bCoalesceMoves=True
bMoveErrorAccumFix=True
NewNetUpdateFrequency=100         ; halve PRI replication load vs 200 baseline
PingTweenTime=1.0                 ; slower ping polling, less RPC volume
MaxPing=0.180                     ; ONS/AS maps tend to have more open sightlines; slightly more generous rewind
PawnCollisionHistoryLength=0.40   ; match the looser rewind
ClientErrorThreshold=40.0         ; looser drift tolerance reduces correction pressure on server
```

**Watch for**: with 16 players × 85 tick, PCC history is 16 × 34 samples in rolling memory, ~540 samples per tick doing `AddHistory` + `RemoveOutdatedHistory`. Should be fine on modern hardware, but this is where you'd notice if the box is too weak.

**If CPU still struggles**: drop `NetServerMaxTickRate=60`. Rewind precision drops to ~14.7 UU worst-case — still under half the 25 UU collision radius, so competitive hit registration stays intact. Past 60 Hz the feel starts to noticeably degrade; below 60 isn't recommended.

### Profile D — LAN clan / sub-60 ms everyone

**Shape**: LAN events, tight same-region clan play, every player under 60 ms ping, 8 players or fewer.

```ini
; UT2004.ini
LanServerMaxTickRate=120          ; full precision, CPU is trivial at 8 players
NetServerMaxTickRate=120

; WSUTComp.ini
bCoalesceMoves=True
bMoveErrorAccumFix=True
MaxPing=0.080                     ; aggressively protect low-ping targets; anyone above 80 ms leads their shots
PawnCollisionMaxRewind=0.120      ; matches the tight ping policy
ClientErrorThreshold=16.0         ; tighter drift tolerance is safe with low-latency + high-FPS clients
CorrectionHalfLife=0.015          ; marginally snappier since corrections will be small anyway
```

**Watch for**: with `MaxPing=0.080`, if anyone unexpected joins with 100+ ping they'll feel meaningful desync. Raise back to 0.150 for mixed sessions.

**Don't push tick past 120**: engine float-precision issues on `Level.TimeSeconds` show up in long matches. No benefit gained above 120 for competitive-tier hit registration.

### Profile-picking cheat sheet

| You run... | Use profile |
|---|---|
| 4v4 comp, clients 240+ FPS | A |
| 10–16 pub mixed | B |
| 14v14 pub, struggling server | C |
| LAN event / clan scrim | D |
| Something in between | Start with baseline, pick deltas from the closest profile |

---

## Symptom → setting guide

### Damage feels hitchy / "rubber band" after taking a hit

- **First try**: confirm `bEnableCorrectionSmoothing=True`, `CorrectionHalfLife=0.020`, `CorrectionJumpThreshold=60`.
- Still draggy: `CorrectionHalfLife=0.015`.
- Shock combos / rockets pulling the view: raise `CorrectionJumpThreshold` to `80`.
- Smoothing causing perceptible lag even on your own corrections: try `bSmoothCameraOffset=False` (mesh still smooths for remote viewers, your camera stays authoritative).

### Sustained fire causes compounding desync (can't recover while being shot)

- Raise `ClientErrorThreshold`: `25` → `40` (~6 UU tolerance) or `64` (8 UU).
- Enable `bMoveErrorAccumFix=True` with `MoveErrorAccumFixValue=0.009`. Tighter polling means drift gets corrected in smaller increments instead of building up.
- Confirm `bCoalesceMoves=True` — helps drain the SavedMove queue so corrections arrive with less stale-input lag.

### Low-ping players complain about "getting shot around corners"

- Lower `MaxPing`: `0.150` → `0.120` or `0.100`. High-ping shooters get less rewind, reducing the window where a target can move behind cover on their own screen before the shooter's rewind-traced shot lands.
- Lower `PawnCollisionMaxRewind` as a secondary cap: `0.240` → `0.180`.

### High-ping players complain about shots missing

- Raise `MaxPing`: `0.150` → `0.200` or `0.250`. Their shots get more rewind compensation, at the cost of the above symptom.
- This is a **zero-sum** trade with the previous. Pick a `MaxPing` that matches your community's typical ping distribution.

### "Exceeded max saved moves" spam in logs

- Enable `bCoalesceMoves=True`. This is the root cause fix — coalescing collapses per-frame inputs into per-tick batches, bringing queue depth down from (client_fps / NetMoveDelta) to ~1/NetMoveDelta regardless of fps.
- If you can't enable coalescing for some reason, raise `MaxSavedMoves` to `500` or `750` as a band-aid.

### Remote players visibly "pop" between positions on ping spikes

- This is expected since rewind-delta smoothing was removed (it was interfering with shock beam correction search). The correction smoother helps on the local pawn but doesn't address the PCC rewind jumpiness for others.
- Tightening `PawnCollisionMaxRewind` (`0.240` → `0.180`) reduces the magnitude of any single pop.
- A spike-rejection median filter on `PredictedPing` already runs (2.5× median clamp with 5-sample window) — spikes should self-heal within 2.5 s.

### Local visible snap when your own pawn takes a correction

- Confirm `bEnableCorrectionSmoothing=True`.
- Confirm `bSmoothCameraOffset=True` (otherwise mesh smooths but your viewpoint doesn't, which feels worse).

### CPU overload / server struggling

- Drop `NetServerMaxTickRate`: `100` → `85`. PCC history granularity still gives sub-10 UU rewind accuracy; you don't lose much.
- Drop `NewNetUpdateFrequency`: `200` → `100`. Halves `NewNet_PRI` replication load.
- Drop `PingTweenTime` poll rate: `0.5` → `1.0`. Slower ping tracking, lower RPC volume.

### Bandwidth tight / clients complaining about choke

- Lower `NetMoveDelta` toward the conservative `0.022` — halves ServerMove RPC rate (45 Hz instead of 91 Hz) at the cost of movement responsiveness.
- Check that `MaxClientRate` / `MaxInternetClientRate` aren't set to exactly `10000` (clamps clients into the slow engine tier — see the 10001 threshold note in the Setting Reference). `100000` is the right ceiling.

### Aim desync on rapid fire (second shot of a burst feels off)

- Covered by the `894df66` commit — `SavedVec`/`SavedRot` now captured unconditionally in `NewNet_ServerStartFire`. No tuning knob needed. If you see this post-fix, it's a different bug.

---

## Tuning methodology

1. **Change one thing at a time.** Netcode settings interact; the only way to isolate which change did what is to test a single delta per session.
2. **Baseline first.** Record current feel with the recommended defaults above before tuning — many long-held tweaks are now counter-productive since the rewrite.
3. **Watch the logs.** `bDebugLogging=True` enables per-correction logging. "Exceeded max saved moves" and "Client Error at X is Y" lines are the signals that most directly map to the settings here.
4. **Test with real ping diversity.** Local-LAN testing hides most of these issues. Use artificial latency (clumsy, tc/netem) or test with actual remote players.
5. **Ping distribution matters.** The right `MaxPing` / `PawnCollisionMaxRewind` depends on who plays on your server. A 30 ms LAN clan needs different values than a mixed international pub.

---

## Change history (netcode-relevant)

- **V24+** (in progress): `MaxPing` and `ClientErrorThreshold` promoted to config. `CorrectionHalfLife` default 0.050 → 0.020, `CorrectionJumpThreshold` 30 → 60. Weapon aim replication: `SavedVec`/`SavedRot` always captured in `NewNet_ServerStartFire` regardless of `NextFireTime` guard. `bCoalesceMoves` added (Xonotic-style input coalescing). `MaxSavedMoves` replication fixed.
- **V23**: Client-side fake projectile crash guards; damage impulse made reliable (now disabled pending rework — see code, not notes).
- **V22**: Ping estimator rewrite (median-of-5, 0.5 s poll, spike reject). Move error grace period. O(n²) `RemoveOutdatedHistory` → single batched remove.

See `CHANGES.md` for the full release log.
