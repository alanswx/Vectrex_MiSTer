library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vectrex_analog_frontend is
end entity;

architecture sim of tb_vectrex_analog_frontend is
	constant CLK_PERIOD : time := 20 ns;
	signal clock, reset : std_logic := '0';
	signal ce : std_logic := '1';
	signal dac_code : signed(8 downto 0) := (others => '0');
	signal dac_raw : std_logic_vector(7 downto 0) := (others => '0');
	signal sh_n, ramp_n, zero_n : std_logic := '1';
	signal mux_sel : std_logic_vector(1 downto 0) := "00";
	signal cy, cref : signed(8 downto 0);
	signal cz, csound : std_logic_vector(7 downto 0);
	signal cx, ciy : signed(19 downto 0);
	signal ay, aref : signed(8 downto 0);
	signal az, asound : std_logic_vector(7 downto 0);
	signal ax, aiy : signed(19 downto 0);
	signal dy, dref : signed(8 downto 0);
	signal dz, dsound : std_logic_vector(7 downto 0);
	signal dx, diy : signed(19 downto 0);
begin
	clock <= not clock after CLK_PERIOD/2;
	compat : entity work.vectrex_analog_frontend
	generic map(G_ENABLE => 0)
	port map(clock, ce, reset, dac_code, dac_raw, sh_n, mux_sel, ramp_n,
		zero_n, cy, cref, cz, csound, cx, ciy);
	analog : entity work.vectrex_analog_frontend
	generic map(G_ENABLE => 1, G_SETTLE_SHIFT => 2, G_ACQUIRE_SHIFT => 2,
		G_DROOP_SHIFT => 3, G_ZERO_SHIFT => 2)
	port map(clock, ce, reset, dac_code, dac_raw, sh_n, mux_sel, ramp_n,
		zero_n, ay, aref, az, asound, ax, aiy);
	calibrated : entity work.vectrex_analog_frontend
	generic map(G_ENABLE => 1)
	port map(clock, ce, reset, dac_code, dac_raw, sh_n, mux_sel, ramp_n,
		zero_n, dy, dref, dz, dsound, dx, diy);

	stim : process
		procedure ticks(n : natural) is
		begin
			for i in 1 to n loop wait until rising_edge(clock); end loop;
			wait for 1 ns;
		end procedure;
		variable acquired, before_zero, held_before : integer;
	begin
		reset <= '1'; ticks(2); reset <= '0';
		dac_code <= to_signed(64, 9); dac_raw <= x"40";
		mux_sel <= "00"; sh_n <= '0'; ticks(1);
		assert cy = to_signed(64, 9)
			report "compatibility sample/hold is not immediate" severity failure;
		acquired := to_integer(ay);
		assert acquired >= 0 and acquired < 64
			report "stateful sample/hold did not show finite acquisition" severity failure;
		ticks(40);
		assert to_integer(ay) >= 60 and to_integer(ay) <= 64
			report "stateful sample/hold failed to converge" severity failure;

		sh_n <= '1'; ticks(8);
		assert to_integer(ay) < 40
			report "disconnected sample/hold did not droop" severity failure;
		assert cy = to_signed(64, 9)
			report "compatibility sample/hold drooped" severity failure;

		-- The schematic-derived default hold needs extra fractional precision:
		-- its roughly 89-second leakage constant must not collapse to a forced
		-- one-Q8-LSB update on every 12 MHz tick.
		sh_n <= '0'; ticks(700); sh_n <= '1';
		assert to_integer(dy) >= 63
			report "calibrated sample/hold acquisition is too slow" severity failure;
		held_before := to_integer(dy); ticks(1200);
		assert to_integer(dy) >= held_before - 1
			report "calibrated sample/hold droop lost fixed-point precision" severity failure;

		sh_n <= '0'; mux_sel <= "01"; dac_code <= to_signed(0, 9);
		dac_raw <= x"00"; ticks(40);
		mux_sel <= "00"; dac_code <= to_signed(64, 9); dac_raw <= x"40";
		ticks(40); sh_n <= '1'; ramp_n <= '0'; ticks(16); ramp_n <= '1';
		assert cx /= 0 and ax /= 0
			report "test failed to build integrator offset" severity failure;
		before_zero := abs(to_integer(ax));
		zero_n <= '0'; ticks(1);
		assert cx = 0 and ciy = 0
			report "compatibility ZERO is not instantaneous" severity failure;
		assert abs(to_integer(ax)) > 0 and abs(to_integer(ax)) < before_zero
			report "stateful ZERO did not begin gradual discharge" severity failure;
		ticks(40);
		assert abs(to_integer(ax)) <= 1 and abs(to_integer(aiy)) <= 1
			report "stateful ZERO failed to converge" severity failure;

		-- Reversing the direct DAC as RAMP opens makes the analog velocity
		-- turn through zero. The compatibility path changes direction at once.
		dac_code <= to_signed(-64, 9); ticks(40);
		zero_n <= '1'; dac_code <= to_signed(64, 9); ramp_n <= '0'; ticks(1);
		assert to_integer(ciy) > 0 and to_integer(aiy) < 0
			report "DAC settling did not preserve the old initial velocity" severity failure;
		ticks(20); ramp_n <= '1';
		assert to_integer(aiy) > 0
			report "settling velocity failed to turn toward the new DAC target" severity failure;

		report "vectrex_analog_frontend tests passed" severity note;
		wait;
	end process;
end architecture;
