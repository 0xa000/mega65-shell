# MEGA65 R6 core-swap prototype — tester guide

> **Update 2026-07-17 (round 5):** the round-4 clocking fix was real but
> evidently not the whole story, so this build makes the board itself
> tell us what the FPGA's internal configuration port did. **Complete new
> build again — use only files from this zip together.**
>
> Two changes matter for you:
>
> 1. **The red mainboard LED now gives a verdict after every serial
>    upload.** During the upload it flickers rapidly with progress as
>    before; once the upload has finished, it shows one of three
>    patterns (and holds it until the next upload or a long reset
>    press):
>    * **solid red** — the configuration port never accepted the
>      stream (this is the failure we are hunting);
>    * **slow blink, about once a second** — the port accepted the
>      stream but flagged an error;
>    * **fast blink, several times a second** — the stream was accepted
>      cleanly; the checkerboard colors should have changed.
>    Please report which pattern you see after each upload, even if the
>    picture looks unchanged — the LED is the measurement this round.
> 2. **Please push the full bitstream with Vivado's Hardware Manager or
>    openFPGALoader this round — not with the m65 tool.** We traced the
>    m65 tool's JTAG code: after programming it reads a status register
>    through the JTAG configuration port and exits **without sending the
>    "desync" command** that releases that port again. The FPGA's
>    configuration engine can then stay captured by JTAG — and while
>    captured, it silently ignores the internal configuration port our
>    serial loader writes to. That would explain your results exactly,
>    every round. (Example: `openFPGALoader --cable ft2232
>    config_a.bit`; Vivado programs it like any bitstream.)
>    If you have the time, one extra cycle the old way — m65 push, then
>    serial upload — and the LED verdict for BOTH cycles would confirm
>    or clear this in one go. Either way, close all JTAG software
>    before each serial upload.
>
> Procedure otherwise unchanged: Test 1, then Test 2 (A → B, report LED
> pattern + whether the colors inverted; more round trips welcome). Two
> bonus observations if you can: does the picture go dark during the
> ~30 s upload, and does the "black screen on first full push until one
> short reset" issue still occur?

> **Update 2026-07-14 (round 4, superseded):** your round-3 report was the golden
> data point — "the colors never change, they stay whatever the full
> bitstream had" told us the serial upload was being received and the
> screen blanked/recovered, but the FPGA's internal configuration port
> was silently **ignoring the stream**: the partials never actually
> reconfigured anything, in any round. Root cause found in the shell's
> clocking (the configuration port was driven at its exact speed limit
> from an unbuffered clock net — a defect the tools don't flag); fixed
> and rebuilt. **This zip is a complete new build: use only files from
> this zip together** (old partials will not match this shell).
> Please re-run Test 2: from config A, push the B partial — the
> checkerboard should now come back **color-inverted without any JTAG
> load**. A→B→A→B… round trips + sprinkled resets welcome, as before.
> The "black screen on first full push until one short reset" issue from
> your report is a separate, known cold-boot race — noting whether it
> also disappears with this build is a useful bonus observation.

> **Update 2026-07-13 (round 3, superseded):** thank you for the round-2 report — it
> pinned down the two remaining failure modes exactly. Both are now
> fixed at the root: the black screen on the *initial* full-bitstream
> push and the lockup you hit after several A/B swaps were the same
> class of bug (memory commands could be silently dropped while the
> memory subsystem initializes and during swaps; the video scaler then
> waited forever). The shell now back-pressures instead of dropping —
> the same revision is hardware-verified on our second board type, where
> cold boots and resets now recover 100% of the time and lockups could
> no longer be reproduced at all.
> **Please re-run Test 1 and Test 2, and be mean to it**: a full push
> with NO reset press should show the checkerboard by itself; many
> A→B→A→B… round trips; resets sprinkled in between. *Normal*: a brief
> moment of stale/garbage picture right when video re-engages after a
> reset, and ~1–2 s of dark screen during a swap. A *persistent* black
> screen or a frozen striped screen is a real finding — please report
> what you did.
> One extra question from round 2: config B should show the demo with
> **inverted colors** vs config A — could you confirm you actually see
> that difference? (If A and B look identical, that's a finding too.)

> **Update 2026-07-12 (round 2, superseded):** fixed the reset race in
> the upstream M2M video scaler (black screen behind menu / striped
> freeze on some resets and swaps).

Thank you for helping test this! This package demonstrates **live core
switching on the MEGA65 via FPGA partial reconfiguration**: a small
"shell" design permanently owns the board's pins and clocks, and the
actual core is a *reconfigurable module* that can be streamed into the
running FPGA over the TE0790's serial port — no reboot, no flashing.

The two included cores are deliberately boring (the MiSTer2MEGA65 demo
core, and the same core with inverted video colors) so that a successful
swap is unmistakable. The interesting part is the swap itself.

## What you need

- A **MEGA65 with the R6 mainboard** (batch 2+ / late-2023 onwards).
  This will *not* work on R3/R3A/R4/R5 boards — the pin constraints are
  R6-specific. If unsure, don't run it; ask first.
- A **TE0790 JTAG module** (the standard MEGA65 debug module) fitted to
  the mainboard's JTAG header, and a micro-USB cable to your PC.
- An HDMI display.
- On the PC:
  - a JTAG programming tool — any one of:
    - `m65` from [mega65-tools](https://github.com/MEGA65/mega65-tools)
      (most MEGA65 testers have this),
    - Vivado / Vivado Lab Edition hardware manager,
    - `openFPGALoader` (FT2232 cable support required);
  - Python 3 with `pyserial` (`pip install pyserial`) for the swap test.

## Is this safe for my MEGA65?

Yes. Everything here is loaded over JTAG into FPGA configuration RAM
only — **nothing is written to the QSPI flash, the SD cards are not
touched, and a power cycle returns your MEGA65 exactly to its installed
cores.** Please do *not* flash these bitstreams into a QSPI core slot;
they are JTAG-only by design.

If anything ever looks stuck: power-cycle. That is always a full
recovery.

## Package contents

| File | What it is |
|---|---|
| `config_a.bit` | full bitstream: shell + demo core (JTAG) |
| `config_b.bit` | full bitstream: shell + inverted demo core (JTAG) |
| `config_a_pblock_RM_partial.bin` | partial: demo core only (serial swap) |
| `config_b_pblock_RM_partial.bin` | partial: inverted demo core only (serial swap) |
| `send_partial.py` | serial upload script for the partials |
| `sha256sums.txt` | checksums |

All four bitstreams come from **one build** and belong together. Don't
mix them with files from another release — a partial from build N loaded
into the shell of build M produces a black screen (harmless, but a wasted
test; JTAG-load a full bitstream to recover).

## Test 1 — shell bring-up (JTAG only)

1. Power on the MEGA65, connect the TE0790 to the PC.
2. Push the full config A bitstream, e.g.:
   - `m65 -b config_a.bit`, or
   - Vivado hardware manager → Open target → Program device →
     `config_a.bit`, or
   - `openFPGALoader --cable ft2232 config_a.bit`
3. Within a few seconds the HDMI display should show the MiSTer2MEGA65
   demo core (start screen; press **Help** for the on-screen menu).

Please note / report:

- Does the monitor accept the picture (720p60 by default)?
- Keyboard: menu navigation with cursor keys + Return, Help opens/closes
  the menu. Space starts the demo "game" (first Space closes the welcome
  screen, second starts it — that's stock demo core behavior).
- Audio over HDMI (the demo game plays sound).
- The **green** mainboard LED (next to the reset button) mirrors the
  core's power LED. The keyboard LEDs are *not* driven in this prototype
  — that's expected, not a fault.
- Optional: the menu's HDMI mode entries (50/60 Hz, 576p/720p) exercise
  the shell's video-clock service — mode changes should come up cleanly
  after the monitor re-syncs.
- Reset button: short press resets the core, holding it ≥ 1.5 s resets
  the whole framework. Both should come back cleanly.

If Test 1 works, the shell is alive on your board — that alone is a
valuable result, please report it even if you stop here.

## Test 2 — live core swap over serial

The shell listens on the TE0790's serial port (2,000,000 baud) for a
partial bitstream and feeds it to the FPGA's internal configuration port.

1. Start from a running config A (Test 1).
2. Close any serial terminal you may have open on the TE0790 port.
3. Find the serial device: the TE0790 shows up as **two** ports; the
   UART is the **second** one (typically `/dev/ttyUSB1` on Linux, the
   higher `COMx` on Windows).
4. Send the *other* core:

   ```
   python3 send_partial.py config_b_pblock_RM_partial.bin --port /dev/ttyUSB1
   ```

5. During the ~30 s upload: the screen goes dark (the monitor loses
   sync — expected, the core producing the picture is being replaced),
   audio is muted, and the **red** mainboard LED blinks with upload
   progress.
6. When the upload completes, the demo core comes back **with inverted
   colors** — that's config B running. Keyboard, menu and audio should
   all work again.
7. Swap back: send `config_a_pblock_RM_partial.bin` the same way.
   Please do at least A → B → A, more round trips welcome.

Please note / report:

- Upload time reported by the script (~26–30 s is nominal).
- Red-LED progress blink present during upload?
- How long until the monitor shows the new core after the upload ends?
- Keyboard + audio functional after each swap?
- Any swap that ends in a black screen or a hang (then: which one, and
  does JTAG-loading `config_a.bit` recover it? It should, always.)

Notes:

- Send **only** the `*_partial.bin` files with the script. The script
  refuses `.bit` files; full bitstreams cannot be loaded this way.
- The upload is deliberately gated on a sync word: stray serial traffic,
  plugging/unplugging the cable, or an interrupted upload cannot corrupt
  the running shell. If an upload is interrupted mid-way the screen
  stays dark — just send the file again from the start.

## Reporting

Please include with your results:

- mainboard revision (R6 batch), display model,
- host OS + JTAG tool used,
- which tests you ran and what you saw (photos welcome, especially of
  anything odd).

Thanks again — every data point from real R6 silicon helps.
