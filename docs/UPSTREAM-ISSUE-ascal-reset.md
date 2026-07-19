# Draft upstream issue (sy2002/MiSTer2MEGA65; heritage note for temlib/MiSTer)

Title: **ascal: `avl_write_i` not cleared by reset — phantom write burst
after reset can permanently kill core video (black boot screen / frozen
striped screen after reset)**

---

## Symptom

Occasionally after a cold boot or a reset press, core video never comes
back while everything else keeps working: OSM/overlay renders, audio
plays, keyboard responds. At cold boot this looks like a black screen
behind the OSM; after a warm reset it can look like a frozen screen of
one repeated stale line (vertical stripes), with no motion. Whether a
given reset survives is roughly a coin flip (biased, and the odds vary
per core/clock setup), so the bug is easy to misattribute to whatever
was changed last. We chased it across two boards and several suspects
before finding the root cause; full investigation log available.

## Root cause

`M2M/vhdl/ascal.vhd`, Avalon-side process `Avaloir`, reset clause:

```vhdl
IF avl_reset_na='0' THEN
  avl_state<=sIDLE;
  ...
  avl_read_i<='0';
  --avl_write_i<='0';     -- <== commented out
```

The process uses an asynchronous reset, so while `avl_reset_na` is low
the synchronous default `avl_write_i<='0'` (top of the clocked body)
never executes. If reset asserts while the avl writer is mid-burst,
`avl_write_i` freezes at `'1'` — with stale address — **for the entire
duration of the reset**, presenting a phantom write request to the
memory chain.

At reset release there is a race: ascal's per-domain reset synchronizer
can release a cycle or two after the avalon chain (avm_fifo /
avm_decrease / arbiter / RAM controller) wakes up. If the chain wins,
it accepts the phantom write header and starts a burst; ascal then
comes out of reset, the synchronous default clears `avl_write_i`, and
the burst is truncated after the one stale beat that was delivered.

Downstream burst bookkeeping never recovers: the width converter /
controller sits waiting for write beats that will never come, and
because avm_decrease re-announces the full narrow burstcount on every
wide beat, each subsequent real write burst rolls the beat debt
forward instead of clearing it. When ascal's output side then issues
its two line-preload reads, they are swallowed by the desynced
component (in our DDR3 backend, `avm_increase` in its write state
accepts a read with `waitrequest='0'` but ignores it; other backends
have equivalent behavior). ascal's output-side read pipeline has no
timeout → permanent deadlock. Black screen at cold boot (zeroed line
buffer) and the striped freeze after a warm reset (stale line replay)
are the same deadlock with different buffer content.

If ascal wins the release race instead, the write is cleared before
anyone samples it and the boot/reset is clean — hence the coin flip.

## Evidence

- Reproduced with flat, unmodified-framework V2.0.1 democore on our
  QMTECH Wukong port (DDR3 backend), and on a MEGA65 R6 running our
  partial-reconfiguration build of the same framework (HyperRAM
  backend) — two boards, two RAM backends, same signature.
- A UART debug tap on the avalon chain caught the wedge live: the
  width converter parked in its write state with remaining beat count
  = 56 — i.e. a 64-beat narrow burst (8 avalon beats × 8) truncated
  after exactly one wide word — and a "read swallowed" event counter
  incrementing by exactly 2 (ascal's two preload reads) at the moment
  video died. Decode tables and captures available on request.
- With the one-line fix below, the same hardware survives arbitrary
  repeated reset presses; the tap shows the phantom gone and zero
  swallowed reads.

## Fix

Restore the clear in the reset clause:

```vhdl
  avl_read_i<='0';
  avl_write_i<='0';
```

That's the entire fix; it is verified on hardware on both of our
boards.

## Notes / honest scoping

- The reset hole itself is unambiguous from the code (the phantom write
  WILL be presented whenever reset lands mid-burst). What we have NOT
  verified is the *severity on unmodified official cores on a stock
  MEGA65*: the permanent deadlock additionally requires a component in
  the memory chain that mishandles the truncated burst + interleaved
  read, and both of our failing chains contain port-specific parts
  (our proven "eater" on the Wukong, avm_increase, is not instantiated
  by upstream). On a stock HyperRAM build the phantom still forms, but
  the outcome could range from the same permanent wedge down to a
  one-frame glitch. If official cores do occasionally boot black or
  freeze striped after a reset — the kind of thing a user fixes with a
  power cycle and never reports — this would be a candidate cause;
  repeated reset presses on an official core would be a quick check.
- The failure probability depends on the video/RAM clock relationship
  (it changes the release-race window and the writer's duty cycle):
  our 50 Hz democore setup wedged on roughly every other reset, a
  VIC20 core much more rarely.
- The commented-out line comes from ascal's upstream heritage
  (temlib / MiSTer), so the report may be worth forwarding there too.
