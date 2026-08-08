# Vectrex Analog Frontend Model

Proposal date: 2026-07-31

> **Status**: the analysis below is the reference; parts of the proposal
> are implemented. Per-path delays exist in `rtl/vectrex_analog_pkg.vhd`
> with identity defaults; the VFB integration this document calls Stage 4
> happened by other means (the vendored Asteroids `videodr0me_fb`); frame
> segmentation is solved by the CA2/Wait_Recal marker in
> `rtl/vectrex_video.sv`; beam energy is in (`docs/beam-model.md`). Two
> model differences vs MAME worth knowing when calibrating the stateful
> analog stage: MAME snaps ZERO to a computed centre after its delay
> (one-shot) where this core and vecx clamp continuously while CA2 is
> low, and both sum the zero-reference DAC into both axes' velocity.
> The referenced `VECTREX_VECTOR_PIPELINE_AUDIT.md` and
> `background_research/` are from the machine this was drafted on and are
> not in this repository.

## Purpose

This document proposes a replacement for the fixed digital delay currently
used by the MiSTer Vectrex core to approximate analog vector-generator timing.

The target is a component-level, fixed-point behavioral model calibrated to a
nominal real Vectrex. It should reproduce the circuit rather than contain
per-game corrections.

This proposal complements:

- `VECTREX_VECTOR_PIPELINE_AUDIT.md`
- The current core under `background_research/Vectrex_MiSTer`

## Sources

Primary hardware and programming references:

- Vectrex Service Manual:
  - https://www.ombertech.com/cnk/vecadapt/Vectrex_service_manual.pdf
- Vectrex Programmer's Manual, Volume I:
  - https://www.vectrex.de/wp-content/uploads/2013/12/vecprogman_v1.pdf
- Vectrex Programmer's Manual, Volume II:
  - https://www.vectrex.co.uk/files/articles/vecprogman_v2.pdf

Implementation reference:

- MAME Vectrex video implementation:
  - https://github.com/mamedev/mame/blob/master/src/mame/miltonbradley/vectrex_v.cpp

The schematics and measurements from real hardware remain authoritative.
MAME is useful evidence, but its analog model is deliberately simplified.

## Current MiSTer Approximation

The existing core samples this complete group at the 12 MHz enable:

```text
CB2, CA2, PB[7:0], PA[7:0]
```

It shifts the group through a 256-entry digital delay buffer and uses tap 94
for PA, PB, and CA2. CB2 blanking is taken directly rather than from the
delayed copy.

The result is approximately:

```text
PA, PB, CA2: delayed by about 7.9 us
CB2:         not delayed
```

The delayed signals then control:

- DAC data;
- multiplexer selection and enable;
- RAMP;
- ZERO;
- the X and Y integrator updates.

This is a coarse analog-timing approximation. It can improve software that
depends on the relative timing of blanking and beam movement, notably the
Clean Sweep maze, but it is not a model of the actual circuit.

The main problems are:

1. Unrelated physical paths are delayed as one digital bus.
2. A complete old PB value takes effect at once, although its individual
   functions travel through different circuitry.
3. The DAC and sample-and-hold nodes have no acquisition or settling state.
4. ZERO clears both digital coordinates instantaneously after the common
   delay.
5. RAMP is an ideal delayed gate.
6. The deflection and intensity outputs have no analog bandwidth.
7. A timing adjustment that helps one access sequence can distort another
   sequence that uses the VIA differently.

The later `beam_blank_buffer` in `vectrex.vhd` is separate. It aligns blanking
with framebuffer address calculation and is not part of this analog-delay
workaround.

## Hardware Behavior to Preserve

Vectrex has no command-list AVG or DVG. The 6809 and 6522 VIA directly operate
the analog vector hardware.

The important controls are:

| Source | Function |
| --- | --- |
| VIA PA[7:0] | Signed DAC code and PSG transfer data |
| VIA PB0 | Analog multiplexer/sample-and-hold enable |
| VIA PB2:1 | Analog multiplexer selection |
| VIA PB7 | Integrator RAMP control, including Timer 1 output |
| VIA CA2 | Integrator ZERO control |
| VIA CB2 | Beam blanking, commonly driven by the VIA shift register |

The service schematic describes one DAC feeding:

- one deflection channel directly;
- the analog multiplexer;
- a sampled second deflection channel;
- a sampled active-ground reference;
- sampled beam intensity;
- the audio destination.

The schematic's axis names and signs must be followed during implementation.
The current RTL and MAME use presentation-oriented internal names that can make
the direct and sampled axes appear transposed.

RAMP controls analog switches in series with the X and Y integrator inputs.
ZERO controls switches across the integration capacitors. The integrator
outputs then drive the deflection amplifier and yoke. These are stateful
analog operations, not delayed assignments to digital coordinates.

## Recommended Architecture

```text
6809 and 6522 VIA
        |
        v
Digital event capture
        |
        v
DAC, mux, and sample-and-hold model
        |
        v
RAMP, ZERO, and X/Y integrator model
        |
        v
Deflection, blanking, and beam-energy model
        |
        v
Timestamped beam samples or segments
        |
        v
Asynchronous source FIFO
        |
        v
125 MHz high-resolution rasterizer and VFB pipeline
```

The machine-side model must run continuously and independently of video
resolution, output cadence, framebuffer availability, and CRT-effect options.
The renderer must never feed back pressure into the emulated analog hardware.

### Suggested RTL Boundaries

Names are provisional:

- `vectrex_analog_events`
  - Captures VIA output transitions with machine-clock timestamps.
  - Preserves Timer 1 and shift-register pin timing.
- `vectrex_dac_mux`
  - Models DAC conversion, settling, multiplexer selection, and the held
    analog channels.
- `vectrex_integrators`
  - Models the active-ground reference, RAMP switches, ZERO switches, and X/Y
    integrator state.
- `vectrex_deflection`
  - Models any calibrated amplifier/yoke bandwidth needed for visible
    geometry.
- `vectrex_beam_frontend`
  - Converts analog state into position, intensity, blanking, and dwell-aware
    beam samples for the renderer.

The boundaries can be combined where that produces clearer RTL. Their
contracts should remain explicit and independently testable.

## Digital Event Timing

### Capture

Capture each externally visible VIA transition on the clock edge where the
production VIA changes its output. Do not reconstruct timing later from CPU
addresses or software intent.

Each event should contain:

```text
event type
new value
machine timestamp
```

Events caused by one VIA operation must retain deterministic simultaneous
semantics.

### Scheduling

Do not replace the existing bus delay with several arbitrary game-specific
delays. Give each physical path its own documented propagation parameter:

- DAC response;
- multiplexer selection;
- sample-and-hold enable;
- RAMP switch;
- ZERO switch;
- blanking path.

MAME uses one `ANALOG_DELAY` value of 8500 ns but schedules the effects as
separate events. That is structurally better than the current whole-bus delay,
although the shared 8.5 us value is still an approximation.

### Efficient FPGA Representation

Run the analog frontend at the existing 24 MHz machine clock. Its 41.67 ns
step is fine enough for microsecond-scale analog behavior. For reference,
8.5 us equals 204 ticks at 24 MHz.

Use small timestamped event queues rather than sampling the complete bus into
thousands of flip-flops. Queue depth must be derived from the maximum number of
VIA output changes possible during the longest modeled delay. Overflow should
be impossible by construction and guarded by a simulation assertion.

If a path ultimately uses one fixed delay, a circular RAM delay can be used,
provided that it stores events or the state for that specific path and retains
the required read-during-write behavior.

## Fixed-Point Analog State

The model should define explicit units for:

- DAC voltage;
- held-channel voltage;
- zero-reference voltage;
- integrator position;
- beam intensity;
- elapsed illuminated time.

Widths and coefficients should be selected against a high-precision golden
model. They should not be guessed solely from the existing display range.

### DAC

A first-order DAC model is sufficient:

```text
dac_target = dac_gain * signed(PA) + dac_offset
dac_state += dac_alpha * (dac_target - dac_state)
```

If measurements show that DAC settling is negligible relative to the other
paths, `dac_alpha` can be one. Gain and offset should still remain explicit.

### Multiplexer and Sample-and-Hold

While a channel is connected to the DAC:

```text
held += acquire_alpha * (dac_state - held)
```

While disconnected:

```text
held += droop_alpha * (hold_reference - held)
```

The expected held channels are the sampled deflection channel, active ground,
and intensity. The fourth multiplexer destination is audio.

Droop can initially be zero if its time constant is much longer than one
display list. The acquisition behavior is more important because software
uses short waits between selecting a channel, writing the DAC, and releasing
the multiplexer.

Multiplexer break-before-make behavior should be included only if confirmed by
the component data and relevant at the chosen simulation step.

### RAMP and Integration

After its own propagation delay, active RAMP connects both deflection
velocities to the integration capacitors:

```text
if ramp_active:
    x_integrator += x_gain * (x_drive - zero_reference)
    y_integrator += y_gain * (y_drive - zero_reference)
```

The signs and assignment of direct and sampled drive values must come from the
schematic. The time step can be folded into the constant gains.

RAMP must affect both axes on the same modeled analog instant even though the
software prepared their values sequentially.

### ZERO

ZERO should model the switches discharging the integration capacitors:

```text
if zero_active:
    x_integrator += zero_alpha_x * (x_center - x_integrator)
    y_integrator += zero_alpha_y * (y_center - y_integrator)
```

An instantaneous reset is acceptable only if measurement shows that the
discharge completes within one model tick. Assertion and release delays can be
different if the hardware demonstrates that behavior.

The active-ground sample-and-hold is part of the deflection reference and must
not be confused with the ZERO operation.

### Deflection Output

The integrator output is not necessarily the beam position at precisely the
same instant. The analog switches, deflection amplifiers, yoke inductance, and
calibration network can add bandwidth limits.

Begin with direct integrator-to-position mapping. If measurements show a
visible transient, add a calibrated first- or second-order response:

```text
deflection += deflection_alpha * (integrator - deflection)
```

Do not tune this stage from one game's screenshot. Use oscilloscope
measurements and standard test patterns.

### Blanking, Intensity, and Dwell

CB2 blanking needs an independent propagation delay. If the CRT grid response
has a measurable rise or fall time, represent it as an intensity envelope
rather than changing a Boolean at an unrelated coordinate boundary.

The held Z voltage should pass through a calibrated intensity transfer:

```text
instant_energy = intensity_transfer(z_voltage) * beam_enable
```

The frontend must preserve illuminated duration. A stationary beam is a dot
with accumulated energy, not a repeated coordinate that can be discarded.
Moving segments must likewise carry enough timing information for the
rasterizer to distribute their energy correctly.

CRT phosphor decay, bloom, halo, slot mask, and color presentation remain
renderer effects. They must not be folded into the machine analog model.

## Beam Output Contract

The frontend should provide either timestamped samples or segments containing:

```text
start position
end position
elapsed machine time
beam enabled
integrated or average intensity
dot/dwell indication where useful
frame/epoch marker
```

The high-resolution rasterizer can interpolate between authentic analog
positions. Interpolation must conserve elapsed beam energy and must not turn a
stationary dwell into a moving line.

The machine and analog frontend should remain in their machine clock family.
Use an asynchronous FIFO to cross into the 125 MHz VFB clock domain. Position,
time, intensity, blanking, and epoch metadata must cross together.

## Frame Segmentation

Vectrex has no hardware AVG halt or DVG list wrap. Software controls the beam
continuously.

VIA Timer 2 behavior can be observed to determine the software display
cadence, but a renderer frame marker must not:

- reset the analog integrators;
- change RAMP, ZERO, or blanking;
- discard pending analog events;
- depend on selected output resolution.

Games that change or temporarily stop their normal Timer 2 cadence require a
documented segmentation policy. The analog beam itself must continue
unmodified even when framebuffer presentation has to reuse or delay a frame.

## Calibration

### Target

There is no single exact physical Vectrex. Component tolerances, aging, and
service adjustments change centering, gain, linearity, and transient response.

The default model should therefore represent:

```text
a nominal, correctly calibrated production Vectrex
```

Calibration constants should live in one documented package. They must not be
scattered through game or renderer logic.

### Measurements

Capture the same controlled test sequence at:

- VIA PA, PB7, CA2, and CB2;
- DAC converter output;
- each sample-and-hold output;
- active-ground reference;
- X and Y integrator outputs;
- blanking or intensity control where safely accessible;
- deflection-amplifier input or an equivalent safe observation point.

Measure:

- digital transition to analog response delay;
- DAC settling;
- sample-and-hold acquisition;
- hold droop;
- RAMP assertion and release;
- ZERO assertion, discharge, and release;
- X and Y integration gain;
- blanking assertion and release;
- Z voltage to visible intensity;
- deflection response at line starts and stops.

At least two calibrated machines would help distinguish intended behavior from
one unit's component tolerances. The service manual's adjustment procedure
should be applied before collecting reference data.

## Golden Model and Verification

### Golden Model

Build a Python or C++ reference using floating-point state first. Once its
behavior is calibrated, add a second implementation using exactly the proposed
RTL fixed-point widths and rounding rules.

For every regression:

1. Record the production VIA output events.
2. Feed the same event trace to the floating-point model.
3. Feed it to the fixed-point model.
4. Feed it to the RTL testbench.
5. Compare every emitted beam sample or segment.

The fixed-point software and RTL results should be bit exact.

### Synthetic Tests

Include:

- DAC minimum, zero, and maximum codes;
- each multiplexer destination;
- short and long sample acquisition windows;
- DAC changes immediately before and after multiplexer release;
- RAMP edges near DAC and mux changes;
- ZERO during idle and active movement;
- blanking edges before, during, and after RAMP;
- back-to-back blanked and visible vectors;
- zero-length illuminated vectors;
- long stationary dots;
- Timer 1 controlled lines;
- shift-register text strokes;
- simultaneous due events;
- event timestamp wrap;
- event-queue capacity.

### Software Regressions

Capture representative traces from:

- BIOS line routines;
- BIOS character routines;
- Mine Storm;
- Clean Sweep maze rendering;
- Spike custom cutscenes with interleaved DAC audio;
- software that directly operates the VIA rather than using BIOS drawing
  routines;
- rapid dots, short vectors, and blanked repositioning.

A single correct still frame is insufficient. Compare consecutive animated
frames and transitions into and out of each drawing routine.

### Acceptance Criteria

- No game-specific timing branch exists.
- Blanked moves never produce visible connecting lines.
- Visible line starts and endpoints match measured hardware within the stated
  tolerance.
- ZERO converges to the calibrated center with the measured timing.
- Dwell brightness is independent of output resolution.
- The same machine trace produces equivalent geometry at 240p, 480p, and 720p.
- Renderer backpressure cannot change machine timing.
- Fixed-point RTL agrees bit exactly with the fixed-point golden model.
- Clean Sweep is correct without degrading BIOS text, Mine Storm, Spike, or
  direct-VIA software.

## Implementation Stages

### Stage 1: Event-Accurate Timing

- Remove the whole-bus delay.
- Capture real VIA output transitions.
- Schedule DAC, mux, RAMP, ZERO, and BLANK independently.
- Retain the existing ideal held values and integrator arithmetic initially.

This is the minimum acceptable structural correction and should remove the
largest source of game-dependent behavior.

### Stage 2: Stateful Analog Frontend

- Add DAC state.
- Add sample-and-hold acquisition.
- Keep the active-ground reference as analog state.
- Replace instant ZERO with calibrated discharge behavior.
- Verify fixed-point integration against the golden model.

### Stage 3: Beam Energy and Output Response

- Calibrate Z-to-intensity response.
- Preserve dwell energy.
- Add measured blanking transitions.
- Add a deflection response model only where measurements justify it.

### Stage 4: VFB Integration

- Emit the complete beam packet through an asynchronous FIFO.
- Add a Vectrex-specific high-resolution sampler.
- Integrate with the modern VFB pipeline.
- Keep machine timing independent of framebuffer and output cadence.

### Stage 5: Hardware Calibration

- Capture real-machine traces.
- Fit the constants.
- Freeze one documented nominal parameter set.
- Run the complete synthetic and software regression suite.

## Recommendation

The production target should be the staged component-level model above. A
full transistor or SPICE simulation is neither necessary nor practical in the
FPGA. Conversely, another fixed bus delay or a Clean Sweep-specific switch
would preserve the underlying architectural error.

The best first implementation is Stage 1 followed immediately by Stage 2.
That provides the important real-hardware semantics while remaining compact,
deterministic, testable, and suitable for timing closure.
