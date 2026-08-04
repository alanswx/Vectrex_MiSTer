derive_pll_clocks
derive_clock_uncertainty


set_false_path -from {emu|hps_io|status*}

# beam_h/beam_v are written and consumed entirely within the clken_12 domain,
# which pulses every second clock, so these paths genuinely have two periods.
# Constraining the source registers by name misses the DSP output register that
# synthesis creates for the lim_* multiply, so target the destinations instead.
set_multicycle_path -to {emu|vectrex|beam_h[*] emu|vectrex|beam_v[*]} -setup 2
set_multicycle_path -to {emu|vectrex|beam_h[*] emu|vectrex|beam_v[*]} -hold 1

# The renderer runs at 125 MHz against the core's 24 MHz. Every crossing goes
# through the framebuffer's own Gray-coded async source FIFO
# (rtl/videodr0me_fb/vfb_rasterizer.sv) or a synchroniser, so the two domains
# are unrelated and must not be timed against each other. Without this every
# clock in the design reports a violation, the core's worst being -44.9ns.
#
# Names taken from the timing report rather than guessed; they are what
# derive_pll_clocks actually produces for these two PLLs.
set core_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set vfb_clk  [get_clocks {emu|pll_vfb|pll_vfb_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set hps_clk  [get_clocks {*|h2f_user0_clk}]

# The audio and HDMI PLLs are framework clocks with no data relationship to
# the renderer, but Quartus still associates some HPS f2sdram bridge registers
# with them, so paths from those into vfb_ddr_arbiter get timed. With periods
# of 40.682ns and 6.732ns against the renderer's 8ns, the worst alignment over
# their least common multiple leaves a 0.752ns capture window, which is why the
# arbiter appeared to miss by 10.5ns on a path only two logic levels deep.
set aud_clk  [get_clocks {pll_audio|*divclk}]
set hdmi_clk [get_clocks {pll_hdmi|*output_counter|divclk}]

# The board oscillators reach the renderer only through reset, which sysmem
# resynchronises into the ram1 domain itself. Timing FPGA_CLK2_50 against the
# 125 MHz clock makes that reset look like a 1.3ns violation on a single level
# of logic, which is the same shape as the other crossings here.
set brd_clk  [get_clocks {FPGA_CLK1_50 FPGA_CLK2_50 FPGA_CLK3_50}]

set_clock_groups -asynchronous \
	-group $core_clk \
	-group $vfb_clk \
	-group $hps_clk \
	-group $aud_clk \
	-group $hdmi_clk \
	-group $brd_clk
