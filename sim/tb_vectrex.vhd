-- Testbench that runs the Vectrex core and extracts analytic beam segments.
--
-- This is the FPGA-side half of the golden-reference comparison. It watches the
-- core's integrators and BLANK and applies the same vectoring rule vecx uses
-- (see alg_sstep in refs/vecx/vecx.c): latch a start point when the beam
-- unblanks, extend it while the beam moves, and emit (x0,y0)-(x1,y1) when the
-- beam blanks or the drawing parameters change.
--
-- Running it here rather than in RTL means the algorithm can be validated
-- against tools/goldenref output before any of it goes into vectrex.vhd.
--
-- The core is not modified; internals are reached via VHDL-2008 external names.
--
-- Emitting segments rather than per-tick samples matters: the core produces
-- 12M beam ticks per emulated second, which is far too much text to write.
--
-- Simulation only. Not part of files.qip.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_vectrex is
	generic
	(
		CART_FILE  : string  := "";      -- hex text, one byte per line
		CART_MASK  : integer := 4095;    -- cartridge size mask (size-1)
		SKIP_MS    : integer := 0;       -- emulated ms to run before capturing
		RUN_MS     : integer := 50;      -- emulated ms to capture
		WARM_MS    : integer := 0;       -- warm reset at this time; 0 disables
		DUMP_FILE  : string  := "seg.txt"
	);
end tb_vectrex;

architecture sim of tb_vectrex is

	constant CLK_PERIOD : time    := 41.666 ns;   -- 24 MHz
	constant MAX_X      : integer := 5625*4*8;    -- matches vectrex.vhd
	constant MAX_Y      : integer := 5625*3*8;

	signal clock : std_logic := '0';
	signal reset : std_logic := '1';
	signal halt  : boolean   := false;

	signal cart_data   : std_logic_vector(7 downto 0)  := (others => '0');
	signal cart_addr   : std_logic_vector(14 downto 0) := (others => '0');
	signal cart_mask_s : std_logic_vector(14 downto 0) :=
	                     std_logic_vector(to_unsigned(CART_MASK, 15));
	signal cart_wr     : std_logic := '0';

	signal video_r, video_g, video_b  : std_logic_vector(7 downto 0);
	signal hblank, vblank, frame_line : std_logic;
	signal audio : signed(9 downto 0);

begin

	clock <= not clock after CLK_PERIOD/2 when not halt else '0';

	dut : entity work.vectrex
	port map
	(
		clock        => clock,
		reset        => reset,
		cpu          => '0',            -- VHDL cpu09; see sim/mc6809_sim.vhd

		cart_data    => cart_data,
		cart_addr    => cart_addr,
		cart_mask    => cart_mask_s,
		cart_wr      => cart_wr,

		video_r      => video_r,
		video_g      => video_g,
		video_b      => video_b,

		frame_line   => frame_line,
		pers         => "01000",
		color        => "00",
		overburn     => '0',

		v_orient     => '0',
		v_width      => std_logic_vector(to_unsigned(540, 10)),
		v_height     => std_logic_vector(to_unsigned(720, 10)),

		video_hblank => hblank,
		video_vblank => vblank,

		speech_mode  => '0',
		audio_out    => audio,

		up_1 => '0', dn_1 => '0', lf_1 => '0', rt_1 => '0',
		pot_x_1 => (others => '0'), pot_y_1 => (others => '0'),

		up_2 => '0', dn_2 => '0', lf_2 => '0', rt_2 => '0',
		pot_x_2 => (others => '0'), pot_y_2 => (others => '0')
	);

	-- ------------------------------------------------------------------
	-- Cartridge load, optional warm reset, then run.
	--
	-- The warm reset reproduces what Vectrex.sv does for "Skip logo": a
	-- second reset shortly after boot makes the BIOS skip its title
	-- sequence, which otherwise runs for seconds of emulated time.
	-- ------------------------------------------------------------------
	stim : process
		file     f      : text;
		variable l      : line;
		variable byte   : integer;
		variable status : file_open_status;
		variable addr   : integer := 0;
	begin
		reset <= '1';
		wait for CLK_PERIOD * 10;

		if CART_FILE /= "" then
			file_open(status, f, CART_FILE, read_mode);
			assert status = open_ok
				report "cannot open cart file: " & CART_FILE severity failure;

			while not endfile(f) loop
				readline(f, l);
				read(l, byte);
				wait until rising_edge(clock);
				cart_addr <= std_logic_vector(to_unsigned(addr, 15));
				cart_data <= std_logic_vector(to_unsigned(byte, 8));
				cart_wr   <= '1';
				wait until rising_edge(clock);
				cart_wr   <= '0';
				addr := addr + 1;
			end loop;
			file_close(f);
			report "loaded " & integer'image(addr) & " cart bytes";
		end if;

		wait for CLK_PERIOD * 10;
		reset <= '0';

		if WARM_MS > 0 then
			wait for WARM_MS * 1 ms;
			report "warm reset (skip logo)";
			reset <= '1';
			wait for CLK_PERIOD * 40;
			reset <= '0';
		end if;

		wait for (SKIP_MS + RUN_MS) * 1 ms;
		halt <= true;
		report "simulation complete";
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- Progress heartbeat. Cheap, and it makes a stalled CPU or a beam that
	-- never unblanks obvious without dumping a waveform.
	-- ------------------------------------------------------------------
	monitor : process
		alias cpu_addr  is << signal dut.cpu_addr     : std_logic_vector(15 downto 0) >>;
		alias blank_raw is << signal dut.beam_blank_n : std_logic >>;
		alias via_pb    is << signal dut.via_pb_o     : std_logic_vector(7 downto 0) >>;
		variable changes   : integer := 0;
		variable unblanked : integer := 0;
		variable prev_a    : std_logic_vector(15 downto 0) := (others => '0');
		variable t_next    : time := 10 ms;
	begin
		loop
			loop
				wait until rising_edge(clock);
				exit when halt or now >= t_next;
				if cpu_addr /= prev_a then
					changes := changes + 1;
					prev_a  := cpu_addr;
				end if;
				if blank_raw = '1' then
					unblanked := unblanked + 1;
				end if;
			end loop;
			t_next := t_next + 10 ms;
			exit when halt;
			-- addr_changes near zero means the CPU is stalled rather than the
			-- program simply not drawing yet; unblank_ticks is the first sign of
			-- the beam being used at all.
			report "t=" & time'image(now) &
			       "  addr_changes=" & integer'image(changes) &
			       "  unblank_ticks=" & integer'image(unblanked) &
			       "  via_pb=" & integer'image(to_integer(unsigned(via_pb)));
		end loop;
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- Vectoring state machine, transcribed from vecx alg_sstep.
	-- ------------------------------------------------------------------
	vectoring : process
		file     f  : text;
		variable l  : line;
		variable st : file_open_status;

		variable vectoring_on : boolean := false;
		variable x0, y0       : integer := 0;
		variable x1, y1       : integer := 0;
		variable dx0, dy0     : integer := 0;   -- deltas when the segment began
		variable col0         : integer := 0;   -- Z when the segment began
		variable prev_x       : integer := 0;
		variable prev_y       : integer := 0;
		variable x, y, dx, dy : integer := 0;
		variable col          : integer := 0;
		variable nseg         : integer := 0;
		variable in_bounds    : boolean;
		variable capturing    : boolean := false;

		-- vecx groups vectors into phosphor-decay periods of VECTREX_MHZ/30
		-- CPU cycles, i.e. 1/30 s. Marking the same boundaries here is what
		-- makes a frame-by-frame diff against tools/goldenref possible.
		constant FRAME_PERIOD : time := 1 sec / 30;
		variable frame_at     : time := 1 sec / 30;
		variable frame_no     : integer := 0;

		-- The core draws with the delayed blank, not the raw CB2, so that is
		-- what the extracted segments must follow to describe what the current
		-- renderer actually puts on screen.
		alias clken_12 is << signal dut.clken_12             : std_logic >>;
		alias int_x    is << signal dut.integrator_x         : signed(19 downto 0) >>;
		alias int_y    is << signal dut.integrator_y         : signed(19 downto 0) >>;
		alias blank_n  is << signal dut.beam_blank_n_delayed : std_logic >>;
		alias dacz     is << signal dut.dac_z                : std_logic_vector(7 downto 0) >>;

		procedure emit(variable lv : inout line) is
		begin
			write(lv, x0); write(lv, string'(" "));
			write(lv, y0); write(lv, string'(" "));
			write(lv, x1); write(lv, string'(" "));
			write(lv, y1); write(lv, string'(" "));
			write(lv, col0);
			writeline(f, lv);
			nseg := nseg + 1;
		end procedure;
	begin
		file_open(st, f, DUMP_FILE, write_mode);
		assert st = open_ok report "cannot open dump file" severity failure;
		write(l, string'("# x0 y0 x1 y1 z   (integrator units, +/-"
		                 & integer'image(MAX_X) & " x +/-" & integer'image(MAX_Y) & ")"));
		writeline(f, l);

		wait until reset = '0';

		loop
			wait until rising_edge(clock);
			exit when halt;

			if not capturing then
				capturing := now >= (SKIP_MS * 1 ms);
			end if;

			if now >= frame_at then
				frame_at := frame_at + FRAME_PERIOD;
				frame_no := frame_no + 1;
				if capturing then
					write(l, string'("# frame "));
					write(l, frame_no);
					writeline(f, l);
				end if;
			end if;

			if clken_12 = '1' then
				x   := to_integer(int_x);
				y   := to_integer(int_y);
				dx  := x - prev_x;
				dy  := y - prev_y;
				col := to_integer(unsigned(dacz));
				in_bounds := (x > -MAX_X) and (x < MAX_X) and
				             (y > -MAX_Y) and (y < MAX_Y);

				if not vectoring_on then
					if blank_n = '1' and in_bounds then
						vectoring_on := true;
						x0 := x; y0 := y; x1 := x; y1 := y;
						dx0 := dx; dy0 := dy; col0 := col;
					end if;
				else
					if blank_n = '0' then
						vectoring_on := false;
						if capturing then emit(l); end if;
					elsif dx /= dx0 or dy /= dy0 or col /= col0 then
						-- Drawing parameters changed mid-vector: close this
						-- segment and start a new one from here.
						if capturing then emit(l); end if;
						if in_bounds then
							x0 := x; y0 := y; x1 := x; y1 := y;
							dx0 := dx; dy0 := dy; col0 := col;
						else
							vectoring_on := false;
						end if;
					end if;
				end if;

				if vectoring_on and in_bounds then
					x1 := x; y1 := y;
				end if;

				prev_x := x;
				prev_y := y;
			end if;
		end loop;

		file_close(f);
		report "extracted " & integer'image(nseg) & " segments to " & DUMP_FILE;
		wait;
	end process;

end sim;
