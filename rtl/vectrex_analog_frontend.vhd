library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vectrex_analog_pkg.all;

-- Stateful model of the Vectrex DAC, mux/sample-and-holds and integrators.
-- All updates happen on the existing 12 MHz beam enable. G_ENABLE=0 is the
-- compatibility implementation factored out of vectrex.vhd verbatim.
entity vectrex_analog_frontend is
	generic
	(
		G_ENABLE        : integer := 0;
		G_SETTLE_SHIFT  : natural := C_DAC_SETTLE_SHIFT;
		G_ACQUIRE_SHIFT : natural := C_SH_ACQUIRE_SHIFT;
		G_DROOP_SHIFT   : natural := C_SH_DROOP_SHIFT;
		G_DROOP_ENABLE  : integer := 1;
		G_ZERO_SHIFT    : natural := C_ZERO_DISCHARGE_SHIFT
	);
	port
	(
		clock        : in  std_logic;
		ce           : in  std_logic;
		reset        : in  std_logic;
		dac_code     : in  signed(8 downto 0);
		dac_raw      : in  std_logic_vector(7 downto 0);
		sh_n         : in  std_logic;
		mux_sel      : in  std_logic_vector(1 downto 0);
		ramp_n       : in  std_logic;
		zero_n       : in  std_logic;
		held_y       : out signed(8 downto 0);
		held_ref     : out signed(8 downto 0);
		held_z       : out std_logic_vector(7 downto 0);
		held_sound   : out std_logic_vector(7 downto 0);
		integrator_x : out signed(19 downto 0);
		integrator_y : out signed(19 downto 0)
	);
end entity;

architecture rtl of vectrex_analog_frontend is
	constant C_FRAC  : natural := C_ANALOG_FRAC_BITS;
	constant C_DAC_W : natural := 9 + C_FRAC;
	constant C_INT_W : natural := 20 + C_FRAC;
	constant C_HOLD_FRAC : natural := C_FRAC + C_HOLD_GUARD_BITS;
	constant C_HOLD_W    : natural := 9 + C_HOLD_FRAC;
	function approach(current_v, target_v : signed; shift_by : natural)
		return signed is
		variable delta_v : signed(current_v'range);
		variable step_v  : signed(current_v'range);
	begin
		delta_v := target_v - current_v;
		if shift_by = 0 then return target_v; end if;
		step_v := shift_right(delta_v, shift_by);
		if step_v = 0 and delta_v > 0 then
			step_v := to_signed(1, step_v'length);
		elsif step_v = 0 and delta_v < 0 then
			step_v := to_signed(-1, step_v'length);
		end if;
		return current_v + step_v;
	end function;

	signal legacy_y, legacy_ref : signed(8 downto 0) := (others => '0');
	signal legacy_z, legacy_sound : std_logic_vector(7 downto 0) := (others => '0');
	signal legacy_x, legacy_iy : signed(19 downto 0) := (others => '0');
	subtype dac_q_t is signed(C_DAC_W-1 downto 0);
	subtype hold_q_t is signed(C_HOLD_W-1 downto 0);
	subtype int_q_t is signed(C_INT_W-1 downto 0);
	signal dac_q : dac_q_t := (others => '0');
	signal y_q, ref_q, z_q, sound_q : hold_q_t := (others => '0');
	signal x_q, iy_q : int_q_t := (others => '0');
	constant C_ZERO_HOLD_Q : hold_q_t := (others => '0');
	constant C_ZERO_INT_Q : int_q_t := (others => '0');
begin
	compat : if G_ENABLE = 0 generate
		process(clock)
		begin
			if rising_edge(clock) and ce = '1' then
				if sh_n = '0' then
					case mux_sel is
						when "00"   => legacy_y     <= dac_code;
						when "01"   => legacy_ref   <= dac_code;
						when "10"   => legacy_z     <= dac_raw;
						when others => legacy_sound <= dac_raw;
					end case;
				end if;
				if zero_n = '0' then
					legacy_x  <= (others => '0');
					legacy_iy <= (others => '0');
				elsif ramp_n = '0' then
					legacy_x  <= legacy_x + (legacy_ref - legacy_y);
					legacy_iy <= legacy_iy - (legacy_ref - dac_code);
				end if;
			end if;
		end process;
		held_y <= legacy_y; held_ref <= legacy_ref;
		held_z <= legacy_z; held_sound <= legacy_sound;
		integrator_x <= legacy_x; integrator_y <= legacy_iy;
	end generate;

	stateful : if G_ENABLE /= 0 generate
		process(clock)
			variable dac_target : dac_q_t;
			variable dac_hold   : hold_q_t;
		begin
			if rising_edge(clock) then
				if reset = '1' then
					dac_q <= (others => '0'); y_q <= (others => '0');
					ref_q <= (others => '0'); z_q <= (others => '0');
					sound_q <= (others => '0'); x_q <= (others => '0');
					iy_q <= (others => '0');
				elsif ce = '1' then
					dac_target := shift_left(resize(dac_code, C_DAC_W), C_FRAC);
					dac_hold := shift_left(resize(dac_q, C_HOLD_W), C_HOLD_GUARD_BITS);
					dac_q <= approach(dac_q, dac_target, G_SETTLE_SHIFT);
					if G_DROOP_ENABLE /= 0 then
						y_q <= approach(y_q, C_ZERO_HOLD_Q, G_DROOP_SHIFT);
						ref_q <= approach(ref_q, C_ZERO_HOLD_Q, G_DROOP_SHIFT);
						z_q <= approach(z_q, C_ZERO_HOLD_Q, G_DROOP_SHIFT);
						sound_q <= approach(sound_q, C_ZERO_HOLD_Q, G_DROOP_SHIFT);
					end if;
					if sh_n = '0' then
						case mux_sel is
							when "00" => y_q <= approach(y_q, dac_hold, G_ACQUIRE_SHIFT);
							when "01" => ref_q <= approach(ref_q, dac_hold, G_ACQUIRE_SHIFT);
							when "10" => z_q <= approach(z_q, dac_hold, G_ACQUIRE_SHIFT);
							when others => sound_q <= approach(sound_q, dac_hold, G_ACQUIRE_SHIFT);
						end case;
					end if;
					if zero_n = '0' then
						x_q <= approach(x_q, C_ZERO_INT_Q, G_ZERO_SHIFT);
						iy_q <= approach(iy_q, C_ZERO_INT_Q, G_ZERO_SHIFT);
					elsif ramp_n = '0' then
						x_q <= x_q + resize(shift_right(ref_q - y_q,
							C_HOLD_GUARD_BITS), C_INT_W);
						iy_q <= iy_q - resize(shift_right(ref_q - dac_hold,
							C_HOLD_GUARD_BITS), C_INT_W);
					end if;
				end if;
			end if;
		end process;
		held_y <= resize(shift_right(y_q, C_HOLD_FRAC), held_y'length);
		held_ref <= resize(shift_right(ref_q, C_HOLD_FRAC), held_ref'length);
		held_z <= std_logic_vector(resize(unsigned(shift_right(z_q, C_HOLD_FRAC)), held_z'length));
		held_sound <= std_logic_vector(resize(unsigned(shift_right(sound_q, C_HOLD_FRAC)), held_sound'length));
		integrator_x <= resize(shift_right(x_q, C_FRAC), integrator_x'length);
		integrator_y <= resize(shift_right(iy_q, C_FRAC), integrator_y'length);
	end generate;
end architecture;
