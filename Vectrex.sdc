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
