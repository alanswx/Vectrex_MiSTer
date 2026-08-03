-- Simulation stand-in for rtl/ym2149.sv.
--
-- ghdl cannot elaborate the SystemVerilog original. Sound has no bearing on
-- beam geometry, so the tone generators are omitted entirely and the channels
-- are held silent. What is kept is the part the Vectrex depends on for
-- non-audio reasons:
--
--   * the address latch and register file, because the BIOS reads the
--     controller buttons through AY register 14 (port A)
--   * IOA_OEn, which the core feeds to vectrex_serial_bit_in for the speech
--     interface; port A stays an input unless register 7 bit 6 says otherwise
--
-- Bus decode follows the standard AY-3-8910 BDIR/BC1 encoding:
--   00 inactive   01 read register   10 write register   11 latch address
--
-- Simulation only. Not part of files.qip.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ym2149 is
port
(
	CLK       : in  std_logic;
	CE        : in  std_logic;
	RESET     : in  std_logic;
	BDIR      : in  std_logic;
	BC        : in  std_logic;
	DI        : in  std_logic_vector(7 downto 0);
	DO        : out std_logic_vector(7 downto 0);
	CHANNEL_A : out std_logic_vector(7 downto 0);
	CHANNEL_B : out std_logic_vector(7 downto 0);
	CHANNEL_C : out std_logic_vector(7 downto 0);

	SEL       : in  std_logic;
	MODE      : in  std_logic;

	IOA_in    : in  std_logic_vector(7 downto 0);
	IOA_out   : out std_logic_vector(7 downto 0);
	IOA_OEn   : out std_logic;

	IOB_in    : in  std_logic_vector(7 downto 0);
	IOB_out   : out std_logic_vector(7 downto 0);
	IOB_OEn   : out std_logic
);
end ym2149;

architecture sim of ym2149 is

	type reg_file_t is array (0 to 15) of std_logic_vector(7 downto 0);
	signal regs     : reg_file_t := (others => (others => '0'));
	signal addr     : unsigned(3 downto 0) := (others => '0');

begin

	process (CLK)
	begin
		if rising_edge(CLK) then
			if RESET = '1' then
				regs <= (others => (others => '0'));
				addr <= (others => '0');
			elsif CE = '1' then
				if BDIR = '1' and BC = '1' then
					-- latch address (only the low nibble is decoded)
					addr <= unsigned(DI(3 downto 0));
				elsif BDIR = '1' and BC = '0' then
					regs(to_integer(addr)) <= DI;
				end if;
			end if;
		end if;
	end process;

	-- Register 14 reads back the port A pins whenever port A is an input,
	-- which is how the Vectrex samples the controller buttons.
	DO <= IOA_in when (addr = 14 and regs(7)(6) = '0') else
	      IOB_in when (addr = 15 and regs(7)(7) = '0') else
	      regs(to_integer(addr));

	IOA_out <= regs(14);
	IOB_out <= regs(15);

	-- Active low: '1' means the chip is not driving the port.
	IOA_OEn <= '0' when regs(7)(6) = '1' else '1';
	IOB_OEn <= '0' when regs(7)(7) = '1' else '1';

	CHANNEL_A <= (others => '0');
	CHANNEL_B <= (others => '0');
	CHANNEL_C <= (others => '0');

end sim;
