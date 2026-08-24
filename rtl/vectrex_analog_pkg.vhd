library ieee;
use ieee.std_logic_1164.all;

-- Analog-path propagation delays, in 12 MHz enable ticks (83.3 ns each).
--
-- The Vectrex has no display processor: the 6809 and the 6522 VIA drive the
-- DAC, multiplexer, sample-and-holds, integrator switches and blanking
-- directly, and each of those signals crosses different analog circuitry
-- with its own propagation and settling time. The original core approximated
-- all of that with a single 94-tap delay of the whole VIA output bus, with
-- blanking taken undelayed; these constants split that into one documented
-- delay per physical path so each can be tuned from measurement without
-- disturbing the others (docs/VECTREX_ANALOG_FRONTEND_MODEL.md, Stage 1).
--
-- The defaults reproduce the original whole-bus behavior exactly: every path
-- at 94 (~7.9 us), blanking at 0 (undelayed). This is also structurally what
-- MAME does: its ANALOG_DELAY of 8500 ns (102 ticks here) applies to the
-- DAC, mux, sample-and-hold and RAMP effects, while CB2 blanking is taken
-- live; vecx delays nothing at all (refs/emulators/NOTES.md). Delaying
-- blanking to 102 was tried and rejected: it moved nearly every segment
-- boundary in a 100 ms Armor Attack run, against both references.
--
-- A tap of 0 means the live, unregistered VIA output. Any other value N is
-- delay_buffer(N) followed by the one-tick output register the original code
-- also had, so relative timing between paths left at 94 is unchanged.

package vectrex_analog_pkg is
	constant C_DELAY_DAC   : integer := 94;  -- PA[7:0] -> DAC code
	constant C_DELAY_SH    : integer := 94;  -- PB0 -> sample/hold enable
	constant C_DELAY_MUX   : integer := 94;  -- PB2:1 -> multiplexer select
	constant C_DELAY_RAMP  : integer := 94;  -- PB7 -> integrator RAMP switch
	constant C_DELAY_ZERO  : integer := 94;  -- CA2 -> integrator ZERO switch
	constant C_DELAY_BLANK : integer := 0;   -- CB2 -> beam blanking

	-- Stage-2 fixed-point frontend. These are deliberately centralized so a
	-- future hardware-derived calibration cannot turn into per-game tuning.
	-- The stateful path is opt-in; ANALOG_MODEL=0 in vectrex preserves the
	-- original integer sample/hold and instantaneous ZERO behavior exactly.
	constant C_ANALOG_FRAC_BITS     : natural := 8;
	constant C_HOLD_GUARD_BITS      : natural := 16; -- resolves multi-second S/H leakage
	constant C_DAC_SETTLE_SHIFT     : natural := 2;  -- tau 0.290 us at 12 MHz
	constant C_SH_ACQUIRE_SHIFT     : natural := 6;  -- tau 5.292 us at 12 MHz
	constant C_SH_DROOP_SHIFT       : natural := 30; -- tau 89.48 s at 12 MHz
	constant C_ZERO_DISCHARGE_SHIFT : natural := 6;  -- tau 5.292 us at 12 MHz
end package;
