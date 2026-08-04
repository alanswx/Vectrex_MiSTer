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
-- Beam state is read through the core's dbg_* ports.
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
		PRESS_MS    : integer := 0;      -- first button tap; 0 disables
		PRESS_COUNT : integer := 1;      -- how many taps
		PRESS_EVERY : integer := 1000;   -- ms between taps
		PRESS_BTN   : integer := 1;      -- 1..4; the Test Cartridge wants 3
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

	-- up_1..rt_1 are the four action buttons; the core folds them into
	-- players_switches. Games sit on their title screen until one is pressed,
	-- so reaching gameplay in simulation needs this.
	-- The core folds up_1..rt_1 into players_switches as buttons 1..4. Note
	-- button 4 is also wired to the CPU's nFIRQ, so menu walking uses 3.
	signal btn : std_logic_vector(4 downto 1) := (others => '0');

	signal beam_x, beam_y : signed(19 downto 0);
	signal beam_blank_n   : std_logic;
	signal beam_z         : std_logic_vector(7 downto 0);
	signal beam_ce        : std_logic;

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

		up_1 => btn(1), dn_1 => btn(2), lf_1 => btn(3), rt_1 => btn(4),
		pot_x_1 => (others => '0'), pot_y_1 => (others => '0'),

		up_2 => '0', dn_2 => '0', lf_2 => '0', rt_2 => '0',
		pot_x_2 => (others => '0'), pot_y_2 => (others => '0'),

		dbg_beam_x  => beam_x,
		dbg_beam_y  => beam_y,
		dbg_blank_n => beam_blank_n,
		dbg_z       => beam_z,
		dbg_ce      => beam_ce
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

		if PRESS_MS > 0 then
			wait for PRESS_MS * 1 ms;
			for i in 1 to PRESS_COUNT loop
				report "button " & integer'image(PRESS_BTN) & " press " &
				       integer'image(i) & " of " & integer'image(PRESS_COUNT);
				btn(PRESS_BTN) <= '1';
				wait for 120 ms;      -- comfortably longer than a poll interval
				btn(PRESS_BTN) <= '0';
				wait for (PRESS_EVERY - 120) * 1 ms;
			end loop;
			wait for (SKIP_MS + RUN_MS) * 1 ms
			         - (PRESS_MS * 1 ms) - (PRESS_COUNT * PRESS_EVERY * 1 ms);
		else
			wait for (SKIP_MS + RUN_MS) * 1 ms;
		end if;
		halt <= true;
		report "simulation complete";
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- Progress heartbeat. Cheap, and it makes a stalled CPU or a beam that
	-- never unblanks obvious without dumping a waveform.
	-- ------------------------------------------------------------------
	-- External names in this process fault under the llvm backend, so the
	-- beam-side diagnostics live in the vectoring process below, which already
	-- holds those aliases. This is a plain time heartbeat.
	monitor : process
	begin
		loop
			wait for 10 ms;
			exit when halt;
			report "t=" & integer'image(now / 1 ms) & "ms";
		end loop;
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- Vectoring state machine, transcribed from vecx alg_sstep.
	-- ------------------------------------------------------------------
	vectoring : process
		file     f  : text;
		variable l   : line;
		variable lframe : line;
		variable st  : file_open_status;

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
		variable unblank_ticks : integer := 0;
		-- Ticks the beam spent inside the current segment. The core writes at
		-- most one framebuffer pixel per clken_12 tick, so comparing a
		-- segment's length in pixels against its tick count says directly
		-- whether the beam outran the splatter and left gaps.
		variable seg_ticks   : integer := 0;
		-- Why segments end. vecx produces far fewer segments per frame than
		-- this extractor does, and these say which rule is over-firing.
		variable n_blank_end : integer := 0;   -- beam blanked
		variable n_delta_end : integer := 0;   -- commanded delta changed
		variable n_col_end   : integer := 0;   -- intensity changed

		-- vecx groups vectors into phosphor-decay periods of VECTREX_MHZ/30
		-- CPU cycles, i.e. 1/30 s. Marking the same boundaries here is what
		-- makes a frame-by-frame diff against tools/goldenref possible.
		constant FRAME_PERIOD : time := 1 sec / 30;
		variable frame_at     : time := 1 sec / 30;
		variable frame_no     : integer := 0;

		-- Read through the core's dbg_* ports rather than VHDL-2008 external
		-- names, which fault under ghdl's llvm backend. The core taps its
		-- delayed blank, not the raw CB2, so these segments describe what the
		-- current renderer actually puts on screen.
		alias clken_12 is beam_ce;
		alias int_x    is beam_x;
		alias int_y    is beam_y;
		alias blank_n  is beam_blank_n;
		alias dacz     is beam_z;

		-- Builds and flushes its own line. Passing a shared line as inout
		-- breaks under the llvm backend, which is stricter than mcode about
		-- writeline leaving the line null.
		procedure emit is
			variable lo : line;
		begin
			write(lo, x0); write(lo, string'(" "));
			write(lo, y0); write(lo, string'(" "));
			write(lo, x1); write(lo, string'(" "));
			write(lo, y1); write(lo, string'(" "));
			write(lo, col0); write(lo, string'(" "));
			write(lo, seg_ticks);
			writeline(f, lo);
			nseg := nseg + 1;
		end procedure;
	begin
		file_open(st, f, DUMP_FILE, write_mode);
		assert st = open_ok report "cannot open dump file" severity failure;
		write(l, string'("# x0 y0 x1 y1 z ticks   (integrator units, +/-"
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
					write(lframe, string'("# frame "));
					write(lframe, frame_no);
					writeline(f, lframe);
					-- Segments stalling at zero means the beam never unblanks,
					-- which looks the same as a stalled CPU from outside.
					report "frame " & integer'image(frame_no) &
					       "  segments=" & integer'image(nseg) &
					       "  ends: blank=" & integer'image(n_blank_end) &
					       " delta=" & integer'image(n_delta_end) &
					       " intensity=" & integer'image(n_col_end);
				end if;
			end if;

			if clken_12 = '1' then
				x   := to_integer(int_x);
				y   := to_integer(int_y);
				dx  := x - prev_x;
				dy  := y - prev_y;
				col := to_integer(unsigned(dacz));
				if blank_n = '1' then
					unblank_ticks := unblank_ticks + 1;
				end if;
				in_bounds := (x > -MAX_X) and (x < MAX_X) and
				             (y > -MAX_Y) and (y < MAX_Y);

				if not vectoring_on then
					if blank_n = '1' and in_bounds then
						vectoring_on := true;
						seg_ticks := 0;
						x0 := x; y0 := y; x1 := x; y1 := y;
						dx0 := dx; dy0 := dy; col0 := col;
					end if;
				else
					if blank_n = '0' then
						vectoring_on := false;
						n_blank_end := n_blank_end + 1;
						if capturing then emit; end if;
					elsif dx /= dx0 or dy /= dy0 or col /= col0 then
						if col /= col0 then
							n_col_end := n_col_end + 1;
						else
							n_delta_end := n_delta_end + 1;
						end if;
						-- Drawing parameters changed mid-vector: close this
						-- segment and start a new one from here.
						if capturing then emit; end if;
						if in_bounds then
							seg_ticks := 0;
							x0 := x; y0 := y; x1 := x; y1 := y;
							dx0 := dx; dy0 := dy; col0 := col;
						else
							vectoring_on := false;
						end if;
					end if;
				end if;

				if vectoring_on then
					seg_ticks := seg_ticks + 1;
					if in_bounds then
						x1 := x; y1 := y;
					end if;
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
