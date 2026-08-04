derive_pll_clocks
derive_clock_uncertainty

set_multicycle_path -from {emu|vectrex|limited_*} -setup 2
set_multicycle_path -from {emu|vectrex|limited_*} -hold 1

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

set_clock_groups -asynchronous -group $core_clk -group $vfb_clk
set_clock_groups -asynchronous -group $hps_clk  -group $vfb_clk
