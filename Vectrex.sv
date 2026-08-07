//============================================================================
//  Vectrex
//
//  Port to MiSTer
//  Copyright (C) 2017-2019 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;


assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// The framework's alternative framebuffer video path is unused, but its
// outputs are declared unconditionally in sys/emu_ports.vh, so drive them
// rather than leaving them floating.
assign FB_EN          = 0;
assign FB_FORMAT      = 0;
assign FB_WIDTH       = 0;
assign FB_HEIGHT      = 0;
assign FB_BASE        = 0;
assign FB_STRIDE      = 0;
assign FB_FORCE_BLANK = 0;



`include "build_id.v" 
localparam CONF_STR = {
	"VECTREX;;",
	"-;",
	"f1,ART;",
	"F1,VECBINROM;",
	"F2,ART,Load Overlay;",
	"OB,Skip logo,No,Yes;",
	"-;",
	// Video menu structured after Videodr0me's Asteroids core: a profiles
	// page whose override entries appear per selected profile (the h masks
	// index status_menumask below), and a timing/geometry page. Custom
	// profile bit positions match Asteroids where free; the old renderer's
	// Frame/Pseudocolor/Overburn entries are gone (legacy path only).
	"P1,Video Profiles & Effects;",
	"P1-;",
	"P1O[68:66],Profile,80s Cruise Control,80s Overdrive,Red Alert,Ultraviolet,Custom 1,Custom 2,Off,A Touch of CRT;",
	"h7P1O[63:61],Dot Scale,2x,2.5x,3x,4x,5x,1x,1.5x;",
	"h7P1O[38:37],Tone Mapping,Off,Linear 1,Linear 2,Bright;",
	"h7P1O[119:118],Inter-Frame Decay,Off,Short,Medium,Long;",
	"h7P1O[56:55],Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"h8P1-;",
	"h8P1-,Modern clarity with a touch;",
	"h8P1-,of old. Subtle halo & bloom;",
	"h8P1-,while vectors stay crisp.;",
	"h9P1-;",
	"h9P1-,The familiar vector CRT glow;",
	"h9P1-,richer halo & stronger bloom;",
	"h9P1-,and a restrained trail.;",
	"hAP1-;",
	"hAP1-,The arcade look you remember;",
	"hAP1-,hot vectors and heavy bloom;",
	"hAP1-,phosphor trails linger.;",
	"hBP1-;",
	"hBP1-,Voltage up. Rules dissolve.;",
	"hBP1-,Red or ultraviolet visions.;",
	"hBP1-;",
	"hBP1-,     Epilepsy warning:;",
	"hBP1-,    excessive flashing;",
	"hDP1O[71:69],> Dot Scale,2x,2.5x,3x,4x,5x,1x,1.5x;",
	"hDP1O[73:72],> Tone Mapping,Off,Linear 1,Linear 2,Bright;",
	"hDP1O[76:74],> Bloom Width,Off,Thin,Tight,Soft,Normal,Broad,Wide-,Wide;",
	"hDH5P1O[79:77],> Bloom Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hDP1O[82:80],> Halo,Off,0.25x,0.33x,0.5x,0.75x,1.0x,1.25x,1.5x;",
	"hDH6P1O[43:41],> Halo Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hDH6P1O[84:83],> Halo Spread,Original,Wide 1,Wide 2,Wide 3;",
	"hDH6P1O[48:47],> Halo Compression,Off,8,16,24;",
	"hDP1O[86:85],> Inter-Frame Decay,Off,Short,Medium,Long;",
	"hDP1O[88:87],> Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"hDP1O[91:89],> Vector Color,White,Deluxe Blue,Lunar Green,Red,Purple,Cyan,Yellow;",
	"hEP1O[94:92],> Dot Scale,2x,2.5x,3x,4x,5x,1x,1.5x;",
	"hEP1O[96:95],> Tone Mapping,Off,Linear 1,Linear 2,Bright;",
	"hEP1O[99:97],> Bloom Width,Off,Thin,Tight,Soft,Normal,Broad,Wide-,Wide;",
	"hEH5P1O[102:100],> Bloom Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hEP1O[105:103],> Halo,Off,0.25x,0.33x,0.5x,0.75x,1.0x,1.25x,1.5x;",
	"hEH6P1O[46:44],> Halo Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hEH6P1O[107:106],> Halo Spread,Original,Wide 1,Wide 2,Wide 3;",
	"hEH6P1O[50:49],> Halo Compression,Off,8,16,24;",
	"hEP1O[109:108],> Inter-Frame Decay,Off,Short,Medium,Long;",
	"hEP1O[111:110],> Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"hEP1O[114:112],> Vector Color,White,Deluxe Blue,Lunar Green,Red,Purple,Cyan,Yellow;",
	"P1-;",
	"P1O[3:2],Persistence,Profile,Short,Medium,Long;",
	"P1-;",
	"P1O[24],Overlay,On,Off;",
	"P1O[27:25],Overlay Bright,100%,90%,80%,70%,60%,50%,40%,30%;",
	"-;",
	"P2,Video Timing & Geometry;",
	"P2-;",
	"P2O[20],Orientation,Horz,Vert;",
	"P2O[17:16],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[19:18],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P2O[28],Render Res,1080p,Match output;",
	"P2O[13],HDMI test pattern,Off,On;",
	"-;",
	"OC,Port 2,Joystick,Speech;",
	"OA,CPU Model,1,2;",
	"-;",
	"R7,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;
// clk_mem / clk_48 / pll_locked are currently unused. They fed the SDRAM
// overlay path; the PLL is left intact because the framebuffer renderer
// will need clk_mem again.
wire clk_mem;
wire clk_48;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_48),
   .locked(pll_locked)
);

// videodr0me_fb runs at 125 MHz; see rtl/pll_vfb for why it needs its own PLL.
wire clk_125;
wire pll_vfb_locked;
pll_vfb pll_vfb
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_125),
	.locked(pll_vfb_locked)
);

///////////////////////////////////////////////////

wire [127:0] status;

// Menu order is Asteroids': +2 mod 8 turns it into the resolver's
// profile numbering (0 Off, 1 Touch, 2 Typical, ... 6/7 Custom).
wire [2:0] vfb_profile = status[68:66] + 3'd2;
wire profile_off        = (vfb_profile == 3'd0);
wire profile_touch      = (vfb_profile == 3'd1);
wire profile_typical    = (vfb_profile == 3'd2);
wire profile_overdriven = (vfb_profile == 3'd3);
wire profile_flashing   = (vfb_profile == 3'd4) || (vfb_profile == 3'd5);
wire profile_custom_1   = (vfb_profile == 3'd6);
wire profile_custom_2   = (vfb_profile == 3'd7);
wire custom_active = profile_custom_1 || profile_custom_2;
wire [2:0] custom_bloom_width = profile_custom_2 ? status[99:97] : status[76:74];
wire [2:0] custom_halo_sel = profile_custom_2 ? status[105:103] : status[82:80];
wire custom_bloom_off = custom_active && (custom_bloom_width == 3'd0);
wire custom_halo_off  = custom_active && (custom_halo_sel == 3'd0);
// The menus put the resolver's encoding-3 (Off) first, as Asteroids does.
wire [1:0] off_tone_mapping = status[38:37] + 2'd3;
wire [1:0] custom_1_tone    = status[73:72] + 2'd3;
wire [1:0] custom_2_tone    = status[96:95] + 2'd3;
wire [27:0] custom_1_settings = {
	status[48:47], status[71:69], custom_1_tone, status[76:74],
	status[79:77], status[82:80], status[43:41], status[84:83],
	status[86:85], status[88:87], status[91:89]};
wire [27:0] custom_2_settings = {
	status[50:49], status[94:92], custom_2_tone, status[99:97],
	status[102:100], status[105:103], status[46:44], status[107:106],
	status[109:108], status[111:110], status[114:112]};
wire  [1:0] buttons;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joya_0, joya_1;
wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	// h-flag visibility for the profiles page, Asteroids' scheme: bit 5
	// bloom-curve hide, 6 halo hides, 7-B per-profile, D/E custom pages.
	.status_menumask({1'b0, profile_custom_2, profile_custom_1, 1'b0,
	                  profile_flashing, profile_overdriven, profile_typical,
	                  profile_touch, profile_off, custom_halo_off,
	                  custom_bloom_off, 5'b0}),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(vfb_ioctl_wait),

	.joystick_l_analog_0(joya_0),
	.joystick_l_analog_1(joya_1),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1)
);

wire [9:0] audio;
assign AUDIO_L = {audio, 6'd0};
assign AUDIO_R = {audio, 6'd0};
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

// Reset on cartridge loads only: the overlay (ioctl index 2) uploads into
// vfb_overlay's DDRAM store, and holding the core in reset through that
// upload wipes it as it arrives.
wire reset = (RESET | status[0] | status[7] | buttons[1] | rom_download | second_reset);

reg second_reset = 0;
always @(posedge clk_sys) begin
	integer timeout = 0;

	if(rom_download && status[11]) timeout <= 5000000;
	else begin
		if(!timeout) second_reset <= 0;
		else begin
			timeout <= timeout - 1;
			if(timeout < 1000) second_reset <= 1;
		end
	end
end


wire hblank, vblank;

assign VGA_SL = 0;
assign VGA_F1 = 0;

// LEGACY_VIDEO restores the original core's entire video path: its internal
// framebuffer, video_freak, and CLK_VIDEO straight off clk_sys. That
// combination is known to drive HDMI on real hardware, so it is the baseline
// to build the new renderer back onto rather than debugging blind.
localparam bit LEGACY_VIDEO = 1'b0;

assign VGA_DE = LEGACY_VIDEO ? ~(hblank | vblank) : ~(vfb_hblank | vfb_vblank);

wire [4:0]  pers[4]   = '{8,4,2,1};
wire [9:0]  width[2]  = '{540, 332};
wire [9:0]  height[2] = '{720, 410};

wire frame_line;

// Aspect ratio, restored from what video_freak used to carry. 9:11 rather
// than the raster's 3:4 is a deliberate choice from commit 30aabc1, so the
// port should not quietly revert it, and the menu's own options still apply.
wire [1:0] ar = status[17:16];

wire        vfb_clk_video, vfb_ce_pixel;
wire        vfb_ioctl_wait, vfb_artwork_available;
wire  [7:0] vfb_r, vfb_g, vfb_b;
wire        vfb_hs, vfb_vs;

generate if (LEGACY_VIDEO) begin : gen_legacy_video
	assign CLK_VIDEO = clk_sys;
	assign CE_PIXEL  = 1;
	assign VGA_HS    = hblank;
	assign VGA_VS    = vblank;
	assign VGA_R     = status[9] & frame_line ? 8'h40 : r;
	assign VGA_G     = status[9] & frame_line ? 8'h00 : g;
	assign VGA_B     = status[9] & frame_line ? 8'h00 : b;

	video_freak video_freak
	(
		.CLK_VIDEO(CLK_VIDEO),
		.CE_PIXEL(CE_PIXEL),
		.VGA_VS(VGA_VS),
		.HDMI_WIDTH(HDMI_WIDTH),
		.HDMI_HEIGHT(HDMI_HEIGHT),
		.VGA_DE(),
		.VIDEO_ARX(VIDEO_ARX),
		.VIDEO_ARY(VIDEO_ARY),
		.VGA_DE_IN(VGA_DE),
		.ARX((!ar) ? (status[20] ? 12'd11 : 12'd9 ) : (ar - 1'd1)),
		.ARY((!ar) ? (status[20] ? 12'd9  : 12'd11) : 12'd0),
		.CROP_SIZE(0),
		.CROP_OFF(0),
		.SCALE(status[19:18])
	);
end else begin : gen_new_video
	assign CLK_VIDEO = vfb_clk_video;
	assign CE_PIXEL  = vfb_ce_pixel;
	assign VGA_R     = vfb_r;
	assign VGA_G     = vfb_g;
	assign VGA_B     = vfb_b;
	assign VGA_HS    = vfb_hs;
	assign VGA_VS    = vfb_vs;

	video_freak video_freak
	(
		.CLK_VIDEO(CLK_VIDEO),
		.CE_PIXEL(CE_PIXEL),
		.VGA_VS(VGA_VS),
		.HDMI_WIDTH(HDMI_WIDTH),
		.HDMI_HEIGHT(HDMI_HEIGHT),
		.VGA_DE(),
		.VIDEO_ARX(VIDEO_ARX),
		.VIDEO_ARY(VIDEO_ARY),
		.VGA_DE_IN(VGA_DE),
		.ARX((!ar) ? (status[20] ? 12'd11 : 12'd9 ) : (ar - 1'd1)),
		.ARY((!ar) ? (status[20] ? 12'd9  : 12'd11) : 12'd0),
		.CROP_SIZE(0),
		.CROP_OFF(0),
		.SCALE(status[19:18])
	);
end endgenerate

// Beam taps from the core, feeding the new renderer.
wire signed [19:0] dbg_beam_x, dbg_beam_y;
wire  [7:0] dbg_z;
wire        dbg_blank_n, dbg_ce, dbg_zero_n;
wire [7:0] r,g,b;


wire rom_download = ioctl_download && (ioctl_index[4:0] <= 1) && (ioctl_index[9:8] == 0);

reg [14:0] addr_mask;
always @(posedge clk_sys) begin
	reg old_download;
	
	old_download <= rom_download;
	if(~old_download & rom_download) addr_mask <= 0;
	if(rom_download && ioctl_wr && (ioctl_addr[14:0] & ~addr_mask)) addr_mask <= ((addr_mask<<1)|15'd1);
end

vectrex #(.INTERNAL_FB(LEGACY_VIDEO ? 1 : 0)) vectrex
(
	.reset(reset),
	.clock(clk_sys),
	.cpu(status[10]),

	.cart_data(ioctl_dout),
	.cart_addr(ioctl_addr),
	.cart_mask(addr_mask),
	.cart_wr(ioctl_wr & ioctl_download & rom_download ),
	
	.video_r(r),
	.video_g(g),
	.video_b(b),

	.video_hblank(hblank),
	.video_vblank(vblank),

	.v_orient(status[20]),
	.v_width(width[0]), //status[4]]),
	.v_height(height[0]), //status[4]]),

	.color(status[6:5]),
	.pers(pers[status[3:2]]),
	.overburn(status[8]),
	.frame_line(frame_line),

	.speech_mode(status[12]),
	.audio_out(audio),

	.up_1(joystick_0[4]),
	.dn_1(joystick_0[5]),
	.lf_1(joystick_0[6]),
	.rt_1(joystick_0[7]),
	.pot_x_1(joya_0[7:0]  ? joya_0[7:0]   : {joystick_0[1], {7{joystick_0[0]}}}),
	.pot_y_1(joya_0[15:8] ? ~joya_0[15:8] : {joystick_0[2], {7{joystick_0[3]}}}),

	.up_2(joystick_1[4]),
	.dn_2(joystick_1[5]),
	.lf_2(joystick_1[6]),
	.rt_2(joystick_1[7]),
	.pot_x_2(joya_1[7:0]  ? joya_1[7:0]   : {joystick_1[1], {7{joystick_1[0]}}}),
	.pot_y_2(joya_1[15:8] ? ~joya_1[15:8] : {joystick_1[2], {7{joystick_1[3]}}}),

	.dbg_beam_x(dbg_beam_x),
	.dbg_beam_y(dbg_beam_y),
	.dbg_blank_n(dbg_blank_n),
	.dbg_z(dbg_z),
	.dbg_ce(dbg_ce),
	.dbg_zero_n(dbg_zero_n)
);


// ---------------------------------------------------------------------------
// Vector presentation. vectrex.vhd is now only a beam source; everything from
// the raster onward lives in videodr0me_fb. See docs/renderer-analysis.md for
// why: the internal framebuffer cannot reach 1080p, has no beam cutoff, no
// dwell term, and is single buffered.
// ---------------------------------------------------------------------------
wire        vfb_hblank, vfb_vblank;

vectrex_video vectrex_video
(
	.clk_sys(clk_sys),
	.clk_125(clk_125),
	.reset(reset),
	.reset_source(reset),

	.beam_x(dbg_beam_x),
	.beam_y(dbg_beam_y),
	.beam_z(dbg_z),
	.beam_on(dbg_blank_n),
	.beam_tick(dbg_ce),
	.beam_zero_n(dbg_zero_n),

	// Rendering at 1080p regardless of the output mode supersamples the
	// beam: the scaler downsamples 810x1080 to 720p/480p, which reads far
	// cleaner than rastering at the output height (Videodr0me's advice).
	.hdmi_height(status[28] ? HDMI_HEIGHT : 12'd1080),

	.v_orient(status[20]),
	.test_pattern(status[13]),

	.overlay_off(status[24]),
	.ovl_bright(status[27:25]),
	.pers_sel(status[3:2]),
	.off_dot_mode(status[63:61]),
	.off_tonemapping(off_tone_mapping),
	.off_inter_frame_decay(status[119:118]),
	.off_intra_frame_decay(status[56:55]),
	.custom1_settings(custom_1_settings),
	.custom2_settings(custom_2_settings),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_addr({2'b00, ioctl_addr}),
	.ioctl_data(ioctl_dout),
	.ioctl_wait(vfb_ioctl_wait),
	.artwork_available(vfb_artwork_available),
	.profile(vfb_profile),
	// Mode 0 swaps on FRAME_DONE + VBL. The marker is now derived from
	// Wait_Recal's CA2 hold rather than the long-blank heuristic that made
	// mode 0 unusable; see vectrex_video's frame marker block.
	.buffer_mode(2'd0),      // EOF + VBL
	.osd_slot_mask_rows(1'b0),

	.clk_video(vfb_clk_video),
	.ce_pixel(vfb_ce_pixel),
	.vga_r(vfb_r),
	.vga_g(vfb_g),
	.vga_b(vfb_b),
	.vga_hs(vfb_hs),
	.vga_vs(vfb_vs),
	.vga_hblank(vfb_hblank),
	.vga_vblank(vfb_vblank),
	.video_arx(),
	.video_ary(),

	.ddram_clk(DDRAM_CLK),
	.ddram_busy(DDRAM_BUSY),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr(DDRAM_ADDR),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_rd(DDRAM_RD),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_we(DDRAM_WE),

	.sdram_dq(SDRAM_DQ),
	.sdram_clk(SDRAM_CLK),
	.sdram_cke(SDRAM_CKE),
	.sdram_ncs(SDRAM_nCS),
	.sdram_nras(SDRAM_nRAS),
	.sdram_ncas(SDRAM_nCAS),
	.sdram_nwe(SDRAM_nWE),
	.sdram_dqml(SDRAM_DQML),
	.sdram_dqmh(SDRAM_DQMH),
	.sdram_a(SDRAM_A),
	.sdram_ba(SDRAM_BA),

	.fifo_full_led()
);

endmodule
