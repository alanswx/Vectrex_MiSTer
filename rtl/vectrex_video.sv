//============================================================================
//  Vectrex high-resolution vector presentation.
//
//  Drives Videodr0me's videodr0me_fb (see rtl/videodr0me_fb/PROVENANCE.md)
//  from the core's beam. Structured after major_havoc_video.sv, which is the
//  reference for how that framebuffer expects to be fed.
//
//  Three things this has to do:
//    * pick a raster size from the display height and generate video timing,
//      because vfb_top consumes h_cnt/v_cnt/ce_pix and syncs rather than
//      producing them
//    * map the core's integrator coordinates into that raster
//    * mark frame boundaries, which the Vectrex has no hardware signal for
//
//  The Vectrex screen is portrait 3:4, so the raster is taller than wide and
//  the display pillarboxes it. That is the opposite of the Atari cores this
//  framebuffer was written for, and the reason the mode table below is not
//  simply copied.
//============================================================================

module vectrex_video
(
	input         clk_sys,        // 24 MHz, the core's clock
	input         clk_125,        // framebuffer and SDRAM clock
	input         reset,
	input         reset_source,

	// Beam, from vectrex.vhd's dbg_* taps. X drives rows, Y drives columns;
	// see vectrex.vhd's beam_v/beam_h derivation.
	input  signed [19:0] beam_x,
	input  signed [19:0] beam_y,
	input   [7:0] beam_z,
	input         beam_on,
	input         beam_tick,      // clken_12

	input  [11:0] hdmi_height,

	// Presentation. A profile resolves the whole effects chain coherently,
	// which is what the Atari cores do; hand-picking the individual settings
	// is how BUFFER_MODE ended up on "VBL only", ignoring FRAME_DONE.
	input   [2:0] profile,
	input   [1:0] buffer_mode,
	// Drives VGA straight from the timing generator with a generated pattern,
	// bypassing vfb_top entirely. If HDMI syncs here but not otherwise, the
	// fault is in the framebuffer's output or its configuration; if it fails
	// here too, the fault is in this module's timing.
	input         test_pattern,
	input         osd_slot_mask_rows,

	// Video out
	output        clk_video,
	output        ce_pixel,
	output  [7:0] vga_r,
	output  [7:0] vga_g,
	output  [7:0] vga_b,
	output        vga_hs,
	output        vga_vs,
	output        vga_hblank,
	output        vga_vblank,
	output [12:0] video_arx,
	output [12:0] video_ary,

	// Framebuffer memory
	output        ddram_clk,
	input         ddram_busy,
	output  [7:0] ddram_burstcnt,
	output [28:0] ddram_addr,
	input  [63:0] ddram_dout,
	input         ddram_dout_ready,
	output        ddram_rd,
	output [63:0] ddram_din,
	output  [7:0] ddram_be,
	output        ddram_we,

	inout  [15:0] sdram_dq,
	output        sdram_clk,
	output        sdram_cke,
	output        sdram_ncs,
	output        sdram_nras,
	output        sdram_ncas,
	output        sdram_nwe,
	output        sdram_dqml,
	output        sdram_dqmh,
	output [12:0] sdram_a,
	output  [1:0] sdram_ba,

	output        fifo_full_led
);

// From rtl/vectrex.vhd: the integrators run +/-max_x by +/-max_y, and max_x
// drives rows while max_y drives columns.
localparam integer MAX_X = 5625 * 4 * 8;   // 180000, vertical full scale
localparam integer MAX_Y = 5625 * 3 * 8;   // 135000, horizontal full scale

// ----------------------------------------------------------------- reset ---
// The top level's reset is a combinational OR of several sources in the core's
// clock domain. Feeding it straight into the 125 MHz logic leaves an
// unsynchronised crossing, which STA reports as a 2-level path from reset_req
// into vfb_phosphor_timing missing by 2.4ns. Asynchronous assert, synchronous
// release, the same shape as major_havoc_reset_sync.
logic [1:0] reset_pipe_125 = 2'b11;
always_ff @(posedge clk_125 or posedge reset) begin
	if (reset) reset_pipe_125 <= 2'b11;
	else       reset_pipe_125 <= {reset_pipe_125[0], 1'b0};
end
wire reset_125 = reset_pipe_125[1];

// ------------------------------------------------------------ mode gate ---
// hdmi_height comes from the framework and is not guaranteed stable. Deriving
// h_total and the sync positions combinationally from it means the raster can
// change mid-frame, which loses sync. Major Havoc gates its timing on a
// mode_ready signal for exactly this reason; this is the same idea, holding
// the mode until the input has been unchanged for a while and keeping the
// timing generator in reset across the change.
localparam integer MODE_SETTLE = 125000;   // 1ms at 125 MHz

logic [11:0] height_meta = 12'd720;
logic [11:0] height_seen = 12'd720;
logic [11:0] height_q    = 12'd720;
logic [17:0] settle_cnt  = 18'd0;
logic        mode_ready  = 1'b0;

always_ff @(posedge clk_125) begin
	height_meta <= hdmi_height;
	height_seen <= height_meta;

	if (reset_125) begin
		height_q   <= height_seen;
		settle_cnt <= 18'd0;
		mode_ready <= 1'b0;
	end
	else if (height_seen != height_q) begin
		height_q   <= height_seen;   // adopt, then wait for it to hold
		settle_cnt <= 18'd0;
		mode_ready <= 1'b0;
	end
	else if (settle_cnt < MODE_SETTLE) begin
		settle_cnt <= settle_cnt + 18'd1;
	end
	else begin
		mode_ready <= 1'b1;
	end
end

wire timing_reset = reset_125 || !mode_ready;

// ---------------------------------------------------------------- modes ---
// Raster sizes are 3:4 to match the Vectrex tube, sized to the display
// height. Scale factors are precomputed rather than divided at runtime:
// vectrex.vhd:477 divides by a signal and that cost the core its timing
// closure, so the same mistake is not repeated here.
//
//   scale = raster_dimension * 2^SHIFT / full_scale_span
localparam integer SHIFT = 22;

logic [11:0] fb_width, fb_height;
logic [11:0] h_total, v_total, hs_start, hs_end, vs_start, vs_end;
logic [31:0] scale_x, scale_y;
logic  [2:0] pix_div;

always_comb begin
	if (height_q >= 12'd1080) begin
		fb_width  = 12'd810;  fb_height = 12'd1080;
		h_total   = 12'd927;  v_total   = 12'd1124;
		hs_start  = 12'd845;  hs_end    = 12'd889;
		vs_start  = 12'd1088; vs_end    = 12'd1093;
		pix_div   = 3'd1;                            // 62.50 MHz
	end
	else if (height_q >= 12'd720) begin
		fb_width  = 12'd540;  fb_height = 12'd720;
		h_total   = 12'd696;  v_total   = 12'd748;
		hs_start  = 12'd578;  hs_end    = 12'd622;
		vs_start  = 12'd728;  vs_end    = 12'd733;
		pix_div   = 3'd2;                            // 31.25 MHz
	end
	else if (height_q >= 12'd480) begin
		fb_width  = 12'd360;  fb_height = 12'd480;
		h_total   = 12'd497;  v_total   = 12'd524;
		hs_start  = 12'd400;  hs_end    = 12'd448;
		vs_start  = 12'd490;  vs_end    = 12'd492;
		pix_div   = 3'd3;                            // 15.62 MHz
	end
	else begin
		fb_width  = 12'd180;  fb_height = 12'd240;
		h_total   = 12'd498;  v_total   = 12'd261;
		hs_start  = 12'd380;  hs_end    = 12'd428;
		vs_start  = 12'd245;  vs_end    = 12'd248;
		pix_div   = 3'd4;                            //  7.81 MHz
	end

	scale_x = (32'(fb_width)  << SHIFT) / (2 * MAX_Y);
	scale_y = (32'(fb_height) << SHIFT) / (2 * MAX_X);
end

assign video_arx = 13'h1000 | 13'(fb_width);
assign video_ary = 13'h1000 | 13'(fb_height);

// -------------------------------------------------------------- timing ---
logic [10:0] h_cnt = 11'd0;
logic [10:0] v_cnt = 11'd0;
logic        raw_hsync, raw_vsync, raw_hblank, raw_vblank;
logic        ce_pix = 1'b0;

// The pixel rate is sized per mode so that horizontal blanking stays sane.
// Running every mode at 125/2 forces h_total to 1388 to reach 60Hz, which
// against a 540 pixel raster is 61% blanking; ascal and the HDMI output path
// do not cope with that, and it is what broke HDMI sync on hardware while VGA
// still worked.
logic [4:0] div_cnt = 5'd0;
always_ff @(posedge clk_125) begin
	div_cnt <= div_cnt + 5'd1;
	ce_pix  <= ((div_cnt & ((5'd1 << pix_div) - 5'd1)) == 5'd0);
	if (timing_reset) begin
		h_cnt   <= 11'd0;
		v_cnt   <= 11'd0;
		div_cnt <= 5'd0;
	end
	else if (ce_pix) begin
		if (h_cnt >= h_total) begin
			h_cnt <= 11'd0;
			v_cnt <= (v_cnt >= v_total) ? 11'd0 : v_cnt + 11'd1;
		end
		else begin
			h_cnt <= h_cnt + 11'd1;
		end
	end
end

assign raw_hsync  = (h_cnt >= hs_start) && (h_cnt < hs_end);
assign raw_vsync  = (v_cnt >= vs_start) && (v_cnt < vs_end);
assign raw_hblank = (h_cnt >= fb_width);
assign raw_vblank = (v_cnt >= fb_height);

// CLK_VIDEO cannot be muxed in fabric: it feeds hdmi_clk_sw and vga_clk_sw,
// hardware Clock Select Blocks, which Quartus requires be driven straight from
// a PLL output or a clock pin. So the diagnostic is a build-time constant,
// which elaborates away and leaves a direct PLL connection.
//
// DIAG_SIMPLE reproduces the original core's video arrangement exactly: 24 MHz
// with CE_PIXEL tied high, its 554x722 raster, and blanking reused as sync.
// That combination is known to drive HDMI on this hardware. Set it to 0 for
// normal operation.
localparam bit DIAG_SIMPLE = 1'b1;

assign clk_video = DIAG_SIMPLE ? clk_sys : clk_125;
assign ce_pixel  = DIAG_SIMPLE ? 1'b1    : ce_pix;

// ------------------------------------------------------------ geometry ---
// Integrator coordinates are signed and centred; shift to unsigned, scale into
// the raster, and clamp. Registered in stages so the multiply gets its own
// clock rather than sitting in a long combinational path.
logic signed [20:0] off_x, off_y;
logic        [51:0] mul_x, mul_y;
logic        [11:0] pix_x, pix_y;
wire          [7:0] z_q;
logic               on_q;
logic         [2:0] tick_pipe;

always_ff @(posedge clk_sys) begin
	// stage 1: centre
	off_y <= 21'(beam_y) + 21'(MAX_Y);   // horizontal
	off_x <= 21'(beam_x) + 21'(MAX_X);   // vertical

	// stage 2: scale
	mul_x <= $unsigned(off_y[20] ? 21'd0 : off_y) * scale_x;
	mul_y <= $unsigned(off_x[20] ? 21'd0 : off_x) * scale_y;

	// stage 3: clamp into the raster
	pix_x <= (mul_x[51:SHIFT] >= fb_width)  ? (fb_width  - 12'd1) : mul_x[SHIFT+11:SHIFT];
	pix_y <= (mul_y[51:SHIFT] >= fb_height) ? (fb_height - 12'd1) : mul_y[SHIFT+11:SHIFT];

	on_q      <= beam_on;
	tick_pipe <= {tick_pipe[1:0], beam_tick};
end

// ----------------------------------------------------------- intensity ---
// Z goes through the framebuffer's own tone mapper rather than straight in,
// which is what the Atari cores do. Passing dac_z raw gives a very dim
// picture, and it is also where the two brightness defects documented in
// docs/renderer-analysis.md get addressed: the core's own path has no beam
// cutoff and no dwell term.
vfb_tone_mapper tone_mapper
(
	.clk_source(clk_sys),
	.reset(reset),
	.beam_on(beam_on),
	.raw_intensity(beam_z),
	.tone_mapping(p_tonemapping),
	.mapped_intensity(z_q)
);

// --------------------------------------------------------- frame marker ---
// The Vectrex has no frame signal. Its BIOS recalibrates once per display
// pass, which shows up as an unusually long stretch with the beam blanked, so
// that is what this looks for. A plain timer would tear against whatever the
// program is drawing.
localparam integer BLANK_GAP = 2000;      // beam_tick counts, about 167us

logic [15:0] blank_run = 16'd0;
logic        frame_done = 1'b0;

always_ff @(posedge clk_sys) begin
	frame_done <= 1'b0;
	if (tick_pipe[0]) begin
		if (on_q) begin
			blank_run <= 16'd0;
		end
		else if (blank_run < 16'hFFFF) begin
			blank_run <= blank_run + 16'd1;
			if (blank_run == BLANK_GAP) frame_done <= 1'b1;
		end
	end
end

// ------------------------------------------------- simple diagnostic path ---
// The test pattern reached VGA but HDMI still would not sync, so the fault is
// not vfb_top. What is left is the clocking: the original core ran CLK_VIDEO
// at 24 MHz with CE_PIXEL tied high, and HDMI worked. This reproduces that
// exactly, on clk_sys, with the original's 554x722 raster and its habit of
// using blanking as sync, so the only variable left is the clock arrangement.
logic [10:0] d_h = 11'd0;
logic [10:0] d_v = 11'd0;
logic        d_hblank = 1'b1;
logic        d_vblank = 1'b1;

localparam integer D_W = 540, D_H = 720;
localparam integer D_HT = D_W + 14;   // 554, as the original
localparam integer D_VT = D_H + 2;    // 722

always_ff @(posedge clk_sys) begin
	if (d_h >= 11'(D_HT - 1)) begin
		d_h <= 11'd0;
		d_v <= (d_v >= 11'(D_VT - 1)) ? 11'd0 : d_v + 11'd1;
	end
	else d_h <= d_h + 11'd1;

	if (d_h == 11'd3)            d_hblank <= 1'b0;
	if (d_h == 11'(D_W + 3))     d_hblank <= 1'b1;
	if (d_v == 11'd0)            d_vblank <= 1'b0;
	if (d_v == 11'(D_H))         d_vblank <= 1'b1;
end

wire       d_active = !d_hblank && !d_vblank;
wire [2:0] d_bar = 3'((d_h * 8) / D_W);
wire       d_border = (d_h == 11'd3) || (d_h == 11'(D_W + 2)) ||
                      (d_v == 11'd0) || (d_v == 11'(D_H - 1));
wire [7:0] d_r = !d_active ? 8'd0 : d_border ? 8'hFF : {8{d_bar[2]}};
wire [7:0] d_g = !d_active ? 8'd0 : d_border ? 8'hFF : {8{d_bar[1]}};
wire [7:0] d_b = !d_active ? 8'd0 : d_border ? 8'hFF : {8{d_bar[0]}};

// -------------------------------------------------------- test pattern ---
// Deliberately plain: full-screen colour bars, a one pixel white border and a
// centre cross. Everything comes from h_cnt/v_cnt, so it exercises the timing
// generator and nothing else.
wire [7:0] fb_vga_r, fb_vga_g, fb_vga_b;
wire       fb_vga_hs, fb_vga_vs, fb_vga_hblank, fb_vga_vblank;

wire [2:0] bar = (fb_width == 12'd0) ? 3'd0 : 3'((h_cnt * 8) / fb_width);
wire       border = (h_cnt == 11'd0) || (h_cnt == 11'(fb_width  - 12'd1)) ||
                    (v_cnt == 11'd0) || (v_cnt == 11'(fb_height - 12'd1));
wire       centre_line  = (h_cnt == 11'(fb_width >> 1)) || (v_cnt == 11'(fb_height >> 1));
wire       active = !raw_hblank && !raw_vblank;

wire [7:0] tp_r = !active ? 8'd0 : (border | centre_line) ? 8'hFF : {8{bar[2]}};
wire [7:0] tp_g = !active ? 8'd0 : (border | centre_line) ? 8'hFF : {8{bar[1]}};
wire [7:0] tp_b = !active ? 8'd0 : (border | centre_line) ? 8'hFF : {8{bar[0]}};

wire use_diag = DIAG_SIMPLE || test_pattern;
assign vga_r      = use_diag ? d_r        : fb_vga_r;
assign vga_g      = use_diag ? d_g        : fb_vga_g;
assign vga_b      = use_diag ? d_b        : fb_vga_b;
assign vga_hs     = use_diag ? d_hblank   : fb_vga_hs;   // as the original
assign vga_vs     = use_diag ? d_vblank   : fb_vga_vs;
assign vga_hblank = test_pattern ? d_hblank   : fb_vga_hblank;
assign vga_vblank = test_pattern ? d_vblank   : fb_vga_vblank;

// ------------------------------------------------------------- profile ---
wire [2:0] p_dot_mode, p_bloom_width, p_bloom_curve, p_halo_filter, p_halo_curve;
wire [2:0] p_presentation_color;
wire [1:0] p_tonemapping, p_halo_spread, p_halo_knee, p_inter_decay, p_intra_decay;
wire       p_color_space, p_slot_mask, p_full_bypass;

vfb_profile_resolver profile_resolver
(
	.profile(profile),
	.fb_height(fb_height),
	.off_dot_mode(3'd0),
	.off_tonemapping(2'd0),
	.off_inter_frame_decay(2'd0),
	.off_intra_frame_decay(2'd0),
	.custom1_settings(30'd0),
	.custom2_settings(30'd0),
	.dot_mode(p_dot_mode),
	.tonemapping(p_tonemapping),
	.bloom_width(p_bloom_width),
	.bloom_curve(p_bloom_curve),
	.halo_filter(p_halo_filter),
	.halo_curve(p_halo_curve),
	.halo_spread(p_halo_spread),
	.halo_knee(p_halo_knee),
	.inter_frame_decay(p_inter_decay),
	.intra_frame_decay(p_intra_decay),
	.color_space(p_color_space),
	.presentation_color(p_presentation_color),
	.slot_mask(p_slot_mask),
	.full_bypass(p_full_bypass)
);

// --------------------------------------------------------- framebuffer ---
logic        sdram_dq_oe;
logic [15:0] sdram_dq_out;
logic  [1:0] sdram_dqm;

assign sdram_clk = ~clk_125;
assign sdram_dq  = sdram_dq_oe ? sdram_dq_out : 16'hzzzz;
assign sdram_dqml = sdram_dqm[0];
assign sdram_dqmh = sdram_dqm[1];

vfb_top framebuffer
(
	.clk_sys(clk_125),
	.clk_source(clk_sys),
	.source_tick(tick_pipe[2]),
	.reset(reset_125),
	.video_timing_reset(timing_reset),

	.X_VECTOR(pix_x[10:0]),
	.Y_VECTOR(pix_y[10:0]),
	.Z_VECTOR(z_q),
	.COLOR(4'b1111),
	.IS_DOT(1'b0),
	.BEAM_ON(on_q),

	.DDRAM_CLK(ddram_clk),
	.DDRAM_BUSY(ddram_busy),
	.DDRAM_BURSTCNT(ddram_burstcnt),
	.DDRAM_ADDR(ddram_addr),
	.DDRAM_DOUT(ddram_dout),
	.DDRAM_DOUT_READY(ddram_dout_ready),
	.DDRAM_RD(ddram_rd),
	.DDRAM_DIN(ddram_din),
	.DDRAM_BE(ddram_be),
	.DDRAM_WE(ddram_we),

	.SDRAM_DQ_IN(sdram_dq),
	.SDRAM_DQ_OUT(sdram_dq_out),
	.SDRAM_DQ_OE(sdram_dq_oe),
	.SDRAM_CKE(sdram_cke),
	.SDRAM_nCS(sdram_ncs),
	.SDRAM_nRAS(sdram_nras),
	.SDRAM_nCAS(sdram_ncas),
	.SDRAM_nWE(sdram_nwe),
	.SDRAM_DQM(sdram_dqm),
	.SDRAM_A(sdram_a),
	.SDRAM_BA(sdram_ba),

	.RENDER_WIDTH(fb_width),
	.RENDER_HEIGHT(fb_height),

	.VGA_R(fb_vga_r),
	.VGA_G(fb_vga_g),
	.VGA_B(fb_vga_b),
	.VGA_HS(fb_vga_hs),
	.VGA_VS(fb_vga_vs),
	.VGA_HBLANK(fb_vga_hblank),
	.VGA_VBLANK(fb_vga_vblank),

	.h_cnt(h_cnt),
	.v_cnt(v_cnt),
	.ce_pix(ce_pix),
	.hsync(raw_hsync),
	.vsync(raw_vsync),
	.hblank(raw_hblank),
	.vblank(raw_vblank),

	.FLASH_PARAM(8'd0),
	.OSD_120HZ(1'b0),
	.FRAME_DONE(frame_done),
	.BUFFER_MODE(buffer_mode),
	.DOT_MODE(dot_mode),
	.FIFO_FULL_LED(fifo_full_led),

	.osd_bloom_width(p_bloom_width),
	.osd_bloom_curve(p_bloom_curve),
	.osd_expand_highlights(p_tonemapping == 2'd2),
	.osd_halo_filter(p_halo_filter),
	.osd_halo_curve(p_halo_curve),
	.osd_halo_knee(p_halo_knee),
	.osd_phosphor_mode(p_intra_decay),
	.osd_inter_frame_phosphor_mode(p_inter_decay),
	.osd_halo_spread(p_halo_spread),
	.osd_color_space(p_color_space),
	.osd_presentation_color(3'd6),
	.osd_slot_mask(p_slot_mask),
	.osd_slot_mask_rows(osd_slot_mask_rows),
	.osd_full_bypass(p_full_bypass)
);

endmodule
