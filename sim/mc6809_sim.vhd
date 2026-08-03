-- Simulation stand-in for rtl/mc6809.v.
--
-- The real wrapper carries two 6809 implementations and selects between them
-- with the CPU input: cpu09 (VHDL, from cpu09l_128a.vhd) when CPU='0' and
-- mc6809is (Verilog) when CPU='1'. ghdl cannot elaborate the Verilog half, so
-- this VHDL replacement instantiates only cpu09 and drives CPU='0' behaviour.
--
-- The E/Q phase generator is a direct transcription of the always block in
-- mc6809.v so cycle timing matches the synthesised core.
--
-- Simulation only. Not part of files.qip.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mc6809 is
port
(
	CPU    : in  std_logic;

	CLK    : in  std_logic;
	CLKEN  : in  std_logic;

	E      : out std_logic;
	riseE  : out std_logic;
	fallE  : out std_logic;

	Q      : out std_logic;
	riseQ  : out std_logic;
	fallQ  : out std_logic;

	Din    : in  std_logic_vector(7 downto 0);
	Dout   : out std_logic_vector(7 downto 0);
	ADDR   : out std_logic_vector(15 downto 0);
	RnW    : out std_logic;

	nIRQ   : in  std_logic := '1';
	nFIRQ  : in  std_logic := '1';
	nNMI   : in  std_logic := '1';
	nHALT  : in  std_logic := '1';
	nRESET : in  std_logic := '1'
);
end mc6809;

architecture sim of mc6809 is

	signal clk_phase : unsigned(1 downto 0) := (others => '0');

	signal e_i     : std_logic := '0';
	signal q_i     : std_logic := '0';
	signal riseE_i : std_logic := '0';
	signal fallE_i : std_logic := '0';
	signal riseQ_i : std_logic := '0';
	signal fallQ_i : std_logic := '0';

begin

	-- Mirrors mc6809.v: one quarter-phase advance per CLKEN, with the strobes
	-- asserted for a single CLK cycle.
	process (CLK)
	begin
		if rising_edge(CLK) then
			fallE_i <= '0';
			fallQ_i <= '0';
			riseE_i <= '0';
			riseQ_i <= '0';

			if CLKEN = '1' then
				clk_phase <= clk_phase + 1;
				case clk_phase is
					when "00"   => e_i <= '0'; fallE_i <= '1';
					when "01"   => q_i <= '1'; riseQ_i <= '1';
					when "10"   => e_i <= '1'; riseE_i <= '1';
					when others => q_i <= '0'; fallQ_i <= '1';
				end case;
			end if;
		end if;
	end process;

	E     <= e_i;
	Q     <= q_i;
	riseE <= riseE_i;
	fallE <= fallE_i;
	riseQ <= riseQ_i;
	fallQ <= fallQ_i;

	-- CPU='0' path only. The real wrapper holds cpu09 in reset when CPU='1';
	-- here we simply always run it, and the testbench drives CPU='0'.
	cpu1 : entity work.cpu09
	port map
	(
		clk      => CLK,
		ce       => fallE_i,
		rst      => (not nRESET) or CPU,
		vma      => open,
		lic_out  => open,
		ifetch   => open,
		opfetch  => open,
		ba       => open,
		bs       => open,
		addr     => ADDR,
		rw       => RnW,
		data_out => Dout,
		data_in  => Din,
		irq      => not nIRQ,
		firq     => not nFIRQ,
		nmi      => not nNMI,
		halt     => not nHALT
	);

end sim;
