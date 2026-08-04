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

wire [1:0] ar = status[17:16];
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? (status[20] ? 12'd11 : 12'd9 ) : (ar - 1'd1)),
	.ARY((!ar) ? (status[20] ? 12'd9  : 12'd11) : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[19:18])
);

`include "build_id.v" 
localparam CONF_STR = {
	"VECTREX;;",
	"-;",
	"F1,VECBINROM;",
	"OB,Skip logo,No,Yes;",
	"-;",
	"OK,Orientation,Horz,Vert;",
	"OGH,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"OIJ,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O9,Frame,No,Yes;",
	// "O4,Resolution,High,Low;" was disabled because low-res ruined the
	// overlay. That constraint is gone; revisit alongside the new renderer.
	"O23,Phosphor persistance,1,2,3,4;",
	"O56,Pseudocolor,Off,1,2,3;",
	"O8,Overburn,No,Yes;",
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

wire [31:0] status;
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

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(0),

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

wire reset = (RESET | status[0] | status[7] | buttons[1] | ioctl_download | second_reset);

reg second_reset = 0;
always @(posedge clk_sys) begin
	integer timeout = 0;

	if(ioctl_download && status[11]) timeout <= 5000000;
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

assign VGA_DE = ~(vfb_hblank | vfb_vblank);

wire [4:0]  pers[4]   = '{8,4,2,1};
wire [9:0]  width[2]  = '{540, 332};
wire [9:0]  height[2] = '{720, 410};

wire frame_line;

// Beam taps from the core, feeding the new renderer.
wire signed [19:0] dbg_beam_x, dbg_beam_y;
wire  [7:0] dbg_z;
wire        dbg_blank_n, dbg_ce;
wire [7:0] r,g,b;


wire rom_download = ioctl_download && (ioctl_index[4:0] <= 1) && (ioctl_index[9:8] == 0);

reg [14:0] addr_mask;
always @(posedge clk_sys) begin
	reg old_download;
	
	old_download <= rom_download;
	if(~old_download & rom_download) addr_mask <= 0;
	if(rom_download && ioctl_wr && (ioctl_addr[14:0] & ~addr_mask)) addr_mask <= ((addr_mask<<1)|15'd1);
end

vectrex #(.INTERNAL_FB(0)) vectrex
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
	.dbg_ce(dbg_ce)
);


// ---------------------------------------------------------------------------
// Vector presentation. vectrex.vhd is now only a beam source; everything from
// the raster onward lives in videodr0me_fb. See docs/renderer-analysis.md for
// why: the internal framebuffer cannot reach 1080p, has no beam cutoff, no
// dwell term, and is single buffered.
// ---------------------------------------------------------------------------
wire        vfb_hblank, vfb_vblank;
wire [12:0] vfb_arx, vfb_ary;

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

	.hdmi_height(HDMI_HEIGHT),

	.buffer_mode(2'd1),
	.dot_mode(3'd0),
	.osd_bloom_width(3'd2),
	.osd_bloom_curve(3'd2),
	.osd_expand_highlights(1'b0),
	.osd_halo_filter(3'd2),
	.osd_halo_curve(3'd2),
	.osd_halo_knee(2'd1),
	.osd_halo_spread(2'd1),
	.osd_phosphor_mode(2'd1),
	.osd_inter_frame_phosphor_mode(2'd1),
	.osd_color_space(1'b0),
	.osd_presentation_color(3'd0),
	.osd_slot_mask(1'b0),
	.osd_slot_mask_rows(1'b0),
	.osd_full_bypass(1'b0),

	.clk_video(CLK_VIDEO),
	.ce_pixel(CE_PIXEL),
	.vga_r(VGA_R),
	.vga_g(VGA_G),
	.vga_b(VGA_B),
	.vga_hs(VGA_HS),
	.vga_vs(VGA_VS),
	.vga_hblank(vfb_hblank),
	.vga_vblank(vfb_vblank),
	.video_arx(vfb_arx),
	.video_ary(vfb_ary),

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
