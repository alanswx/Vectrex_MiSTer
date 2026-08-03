-- Behavioural stand-ins for the three generic memories in rtl/.
--
-- The originals wrap Altera's altsyncram, which ghdl cannot elaborate without
-- the vendor simulation libraries. These match the entity interfaces exactly
-- and model plain synchronous memory: registered read, write-first ignored
-- (the core never reads and writes the same address in the same cycle on any
-- of these).
--
-- Simulation only. Not part of files.qip.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ---------------------------------------------------------------- gen_rom --
-- Dual-clock ROM with a write port, used for the cartridge image.

entity gen_rom is
port
(
	data      : in  std_logic_vector(7 downto 0);
	rdaddress : in  std_logic_vector(14 downto 0);
	rdclock   : in  std_logic;
	wraddress : in  std_logic_vector(14 downto 0);
	wrclock   : in  std_logic := '1';
	wren      : in  std_logic := '0';
	q         : out std_logic_vector(7 downto 0)
);
end gen_rom;

architecture sim of gen_rom is
	type mem_t is array (0 to 32767) of std_logic_vector(7 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
begin
	process (wrclock)
	begin
		if rising_edge(wrclock) then
			if wren = '1' then
				mem(to_integer(unsigned(wraddress))) := data;
			end if;
		end if;
	end process;

	process (rdclock)
	begin
		if rising_edge(rdclock) then
			q <= mem(to_integer(unsigned(rdaddress)));
		end if;
	end process;
end sim;

-- ---------------------------------------------------------------- gen_ram --
-- Single-port RAM. The core uses this for the four video scan buffers, which
-- are large, so the array is sized from the generic rather than fixed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gen_ram is
	generic
	(
		dWidth : integer;
		aWidth : integer;
		nWords : integer
	);
	port
	(
		clk  : in  std_logic;
		we   : in  std_logic;
		addr : in  std_logic_vector(aWidth-1 downto 0);
		d    : in  std_logic_vector(dWidth-1 downto 0);
		q    : out std_logic_vector(dWidth-1 downto 0)
	);
end entity;

architecture sim of gen_ram is
	type mem_t is array (0 to nWords-1) of std_logic_vector(dWidth-1 downto 0);
	signal mem : mem_t := (others => (others => '0'));
begin
	process (clk)
		variable a : integer;
	begin
		if rising_edge(clk) then
			a := to_integer(unsigned(addr));
			-- The video buffers are addressed by computed beam coordinates,
			-- which can transiently exceed nWords during reset; clamp rather
			-- than let the simulation die on a bounds check.
			if a < nWords then
				if we = '1' then
					mem(a) <= d;
				end if;
				q <= mem(a);
			else
				q <= (others => '0');
			end if;
		end if;
	end process;
end sim;

-- -------------------------------------------------------------- gen_dpram --
-- True dual-port RAM, used for the 1K of Vectrex work RAM.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gen_dpram is
	generic
	(
		addr_width_g : integer := 8;
		data_width_g : integer := 8
	);
	port
	(
		address_a : in  std_logic_vector(addr_width_g-1 downto 0);
		address_b : in  std_logic_vector(addr_width_g-1 downto 0);
		clock_a   : in  std_logic := '1';
		clock_b   : in  std_logic;
		data_a    : in  std_logic_vector(data_width_g-1 downto 0);
		data_b    : in  std_logic_vector(data_width_g-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		enable_b  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		wren_b    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width_g-1 downto 0);
		q_b       : out std_logic_vector(data_width_g-1 downto 0)
	);
end gen_dpram;

architecture sim of gen_dpram is
	type mem_t is array (0 to 2**addr_width_g - 1) of std_logic_vector(data_width_g-1 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
begin
	process (clock_a)
	begin
		if rising_edge(clock_a) then
			if enable_a = '1' then
				if wren_a = '1' then
					mem(to_integer(unsigned(address_a))) := data_a;
				end if;
				q_a <= mem(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;

	process (clock_b)
	begin
		if rising_edge(clock_b) then
			if enable_b = '1' then
				if wren_b = '1' then
					mem(to_integer(unsigned(address_b))) := data_b;
				end if;
				q_b <= mem(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;
end sim;
