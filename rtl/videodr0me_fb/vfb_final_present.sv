// ============================================================================
// Final CRT presentation stage.
// written 2026 by Videodr0me
//
// Runs after primary, bloom, halo, and decay processing. It applies the
// selected vector color, overrange spill, and slot mask only to final video.
//
// Pipeline:
//   C1: color-space and presentation-color mapping, spill preparation
//   C2: natural overrange spill and exact-255 white expansion
//   C3: orientation-aware slot mask with bright-pixel gap closure
//   C4: final VGA-facing packet register
//
// RGB and sync/blank always travel as one packet.
// ============================================================================

module vfb_final_present (
	input  logic        clk_sys,
	input  logic        reset,
	input  logic        ce_pix,

	input  logic        color_space_amp709,
	input  logic [2:0]  presentation_color,
	input  logic        slot_mask_enable,
	input  logic        slot_mask_rows,

	input  logic [8:0]  VGA_R_IN,
	input  logic [8:0]  VGA_G_IN,
	input  logic [8:0]  VGA_B_IN,
	input  logic        source_is_255,
	input  logic        VGA_HS_IN,
	input  logic        VGA_VS_IN,
	input  logic        VGA_HBLANK_IN,
	input  logic        VGA_VBLANK_IN,

	output logic [7:0]  VGA_R_OUT,
	output logic [7:0]  VGA_G_OUT,
	output logic [7:0]  VGA_B_OUT,
	output logic        VGA_HS_OUT,
	output logic        VGA_VS_OUT,
	output logic        VGA_HBLANK_OUT,
	output logic        VGA_VBLANK_OUT
);
	localparam logic [2:0] COLOR_WHITE       = 3'd0;
	localparam logic [2:0] COLOR_DELUXE_BLUE = 3'd1;
	localparam logic [2:0] COLOR_LUNAR       = 3'd2;
	localparam logic [2:0] COLOR_RED         = 3'd3;
	localparam logic [2:0] COLOR_PURPLE      = 3'd4;
	localparam logic [2:0] COLOR_CYAN        = 3'd5;
	localparam logic [2:0] COLOR_YELLOW      = 3'd6;
	logic       color_space_amp709_q = 1'b0;
	logic [2:0] presentation_color_q = COLOR_WHITE;
	logic       slot_mask_enable_q = 1'b0;
	logic       slot_mask_rows_q = 1'b0;

	always_ff @(posedge clk_sys) begin
		color_space_amp709_q <= color_space_amp709;
		presentation_color_q <= presentation_color;
		slot_mask_enable_q <= slot_mask_enable;
		slot_mask_rows_q <= slot_mask_rows;
	end

	function automatic [5:0] div7_u8(input logic [7:0] value);
		logic [16:0] product_293;
		begin
			// Exact floor(value / 7) for every 8-bit input:
			// floor(n/7) == (n * 293) >> 11, for n=0..255.
			// 293 = 256 + 32 + 4 + 1, implemented as shift-add.
			product_293 =
				({9'd0, value} << 8) +
				({9'd0, value} << 5) +
				({9'd0, value} << 2) +
				{9'd0, value};
			div7_u8 = product_293[16:11];
		end
	endfunction

	function automatic [7:0] clamp_add_lift(
		input logic [7:0] channel,
		input logic [5:0] lift
	);
		logic [8:0] sum;
		begin
			sum = {1'b0, channel} + {3'b000, lift};
			clamp_add_lift = sum[8] ? 8'hff : sum[7:0];
		end
	endfunction

	function automatic [7:0] scale_14_16(input logic [7:0] channel);
		logic [10:0] scaled;
		begin
			// Exact round(channel * 14 / 16), reduced to
			// floor((channel * 7 + 4) / 8).
			scaled = ({3'd0, channel} << 3) -
			         {3'd0, channel} +
			         11'd4;
			scale_14_16 = scaled[10:3];
		end
	endfunction

	function automatic [7:0] scale_deluxe_blue_red(input logic [7:0] channel);
		logic [8:0] scaled;
		begin
			scaled = {1'b0, channel} + 9'd1;
			scale_deluxe_blue_red = scaled[8:1];
		end
	endfunction

	function automatic [7:0] scale_deluxe_blue_green(input logic [7:0] channel);
		logic [13:0] scaled;
		begin
			// round(channel * 45 / 64), where 45 = 32 + 8 + 4 + 1.
			scaled =
				({6'd0, channel} << 5) +
				({6'd0, channel} << 3) +
				({6'd0, channel} << 2) +
				{6'd0, channel} + 14'd32;
			scale_deluxe_blue_green = scaled[13:6];
		end
	endfunction

	function automatic [7:0] scale_lunar_blue(input logic [7:0] channel);
		logic [8:0] numerator;
		logic [16:0] product_171;
		begin
			// Lunar green uses the selected 519 nm reference, RGB(0, 255, 170).
			// 171/512 gives floor((2*n+1)/3) exactly for every 8-bit input.
			numerator = {channel, 1'b0} + 9'd1;
			product_171 =
				(({8'd0, numerator} << 7) +
				 ({8'd0, numerator} << 5)) +
				(({8'd0, numerator} << 3) +
				 ({8'd0, numerator} << 1)) +
				 {8'd0, numerator};
			scale_lunar_blue = product_171[16:9];
		end
	endfunction

	function automatic [7:0] max3_u8(
		input logic [7:0] a,
		input logic [7:0] b,
		input logic [7:0] c
	);
		logic [7:0] ab;
		begin
			ab = (a > b) ? a : b;
			max3_u8 = (ab > c) ? ab : c;
		end
	endfunction

	function automatic [8:0] max3_u9(
		input logic [8:0] a,
		input logic [8:0] b,
		input logic [8:0] c
	);
		logic [8:0] ab;
		begin
			ab = (a > b) ? a : b;
			max3_u9 = (ab > c) ? ab : c;
		end
	endfunction

	function automatic [7:0] clamp_u9(input logic [8:0] value);
		begin
			clamp_u9 = value[8] ? 8'hff : value[7:0];
		end
	endfunction

	function automatic [7:0] add_spill(
		input logic [7:0] base,
		input logic [7:0] spill
	);
		logic [8:0] sum;
		begin
			sum = {1'b0, base} + {1'b0, spill};
			add_spill = sum[8] ? 8'hff : sum[7:0];
		end
	endfunction

	logic [7:0] base_r_q;
	logic [7:0] base_g_q;
	logic [7:0] base_b_q;
	logic [7:0] spill_q;
	logic source_is_255_q;
	logic base_hs_q;
	logic base_vs_q;
	logic base_hblank_q;
	logic base_vblank_q;

	logic [7:0] ch_r;
	logic [7:0] ch_g;
	logic [7:0] ch_b;
	logic ch_hs;
	logic ch_vs;
	logic ch_hblank;
	logic ch_vblank;

	logic [7:0] selected_r;
	logic [7:0] selected_g;
	logic [7:0] selected_b;
	logic selected_hs;
	logic selected_vs;
	logic selected_hblank;
	logic selected_vblank;

	logic slot_column_parity;
	logic slot_row_parity;
	logic slot_line_active;

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			base_r_q <= 8'd0;
			base_g_q <= 8'd0;
			base_b_q <= 8'd0;
			spill_q <= 8'd0;
			source_is_255_q <= 1'b0;
			base_hs_q <= 1'b1;
			base_vs_q <= 1'b1;
			base_hblank_q <= 1'b1;
			base_vblank_q <= 1'b1;
		end else if (ce_pix) begin
			logic [5:0] blue_lift;
			logic [7:0] color_r;
			logic [7:0] color_g;
			logic [7:0] color_b;
			logic [7:0] mapped_r;
			logic [7:0] mapped_g;
			logic [7:0] mapped_b;
			logic [8:0] peak_energy;
			logic [8:0] spill_energy;

			base_hs_q <= VGA_HS_IN;
			base_vs_q <= VGA_VS_IN;
			base_hblank_q <= VGA_HBLANK_IN;
			base_vblank_q <= VGA_VBLANK_IN;
			if (VGA_HBLANK_IN || VGA_VBLANK_IN) begin
				base_r_q <= 8'd0;
				base_g_q <= 8'd0;
				base_b_q <= 8'd0;
				spill_q <= 8'd0;
				source_is_255_q <= 1'b0;
			end else begin
				peak_energy = max3_u9(VGA_R_IN, VGA_G_IN, VGA_B_IN);
				if (color_space_amp709_q) begin
					blue_lift = div7_u8(clamp_u9(VGA_B_IN));
					color_r = clamp_add_lift(clamp_u9(VGA_R_IN), blue_lift);
					color_g = clamp_add_lift(clamp_u9(VGA_G_IN), blue_lift);
					color_b = clamp_u9(VGA_B_IN);
				end else begin
					color_r = clamp_u9(VGA_R_IN);
					color_g = clamp_u9(VGA_G_IN);
					color_b = clamp_u9(VGA_B_IN);
				end

				case (presentation_color_q)
					COLOR_WHITE: begin
						mapped_r = color_r;
						mapped_g = color_g;
						mapped_b = color_b;
					end
					COLOR_DELUXE_BLUE: begin
						mapped_r = scale_deluxe_blue_red(color_r);
						mapped_g = scale_deluxe_blue_green(color_g);
						mapped_b = color_b;
					end
					COLOR_LUNAR: begin
						mapped_r = 8'd0;
						mapped_g = color_g;
						mapped_b = scale_lunar_blue(color_b);
					end
					COLOR_RED: begin
						mapped_r = color_r;
						mapped_g = 8'd0;
						mapped_b = 8'd0;
					end
					COLOR_PURPLE: begin
						mapped_r = color_r;
						mapped_g = 8'd0;
						mapped_b = color_b;
					end
					COLOR_CYAN: begin
						mapped_r = 8'd0;
						mapped_g = color_g;
						mapped_b = color_b;
					end
					COLOR_YELLOW: begin
						mapped_r = color_r;
						mapped_g = color_g;
						mapped_b = 8'd0;
					end
					default: begin
						mapped_r = color_r;
						mapped_g = color_g;
						mapped_b = color_b;
					end
				endcase

				base_r_q <= mapped_r;
				base_g_q <= mapped_g;
				base_b_q <= mapped_b;
				spill_energy = (peak_energy > 9'd255) ?
					(peak_energy - 9'd255) : 9'd0;
				spill_q <= spill_energy[7:0];
				source_is_255_q <= source_is_255;
			end
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			ch_r <= 8'd0;
			ch_g <= 8'd0;
			ch_b <= 8'd0;
			ch_hs <= 1'b1;
			ch_vs <= 1'b1;
			ch_hblank <= 1'b1;
			ch_vblank <= 1'b1;
		end else if (ce_pix) begin
			ch_hs <= base_hs_q;
			ch_vs <= base_vs_q;
			ch_hblank <= base_hblank_q;
			ch_vblank <= base_vblank_q;
			if (source_is_255_q) begin
				ch_r <= 8'hff;
				ch_g <= 8'hff;
				ch_b <= 8'hff;
			end else begin
				ch_r <= add_spill(base_r_q, spill_q);
				ch_g <= add_spill(base_g_q, spill_q);
				ch_b <= add_spill(base_b_q, spill_q);
			end
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			selected_r <= 8'd0;
			selected_g <= 8'd0;
			selected_b <= 8'd0;
			selected_hs <= 1'b1;
			selected_vs <= 1'b1;
			selected_hblank <= 1'b1;
			selected_vblank <= 1'b1;
			slot_column_parity <= 1'b0;
			slot_row_parity <= 1'b0;
			slot_line_active <= 1'b0;
		end else if (ce_pix) begin
			logic gap_position;
			logic close_gap;

			selected_hs <= ch_hs;
			selected_vs <= ch_vs;
			selected_hblank <= ch_hblank;
			selected_vblank <= ch_vblank;

			gap_position = slot_mask_enable_q &&
			               (slot_mask_rows_q ? slot_row_parity :
			                                 slot_column_parity);
			close_gap = (max3_u8(ch_r, ch_g, ch_b) >= 8'd200);

			if (ch_hblank || ch_vblank) begin
				selected_r <= 8'd0;
				selected_g <= 8'd0;
				selected_b <= 8'd0;
				slot_column_parity <= 1'b0;
				if (ch_vblank) begin
					slot_row_parity <= 1'b0;
					slot_line_active <= 1'b0;
				end else begin
					if (slot_line_active)
						slot_row_parity <= ~slot_row_parity;
					slot_line_active <= 1'b0;
				end
			end else begin
				if (gap_position && !close_gap) begin
					selected_r <= scale_14_16(ch_r);
					selected_g <= scale_14_16(ch_g);
					selected_b <= scale_14_16(ch_b);
				end else begin
					selected_r <= ch_r;
					selected_g <= ch_g;
					selected_b <= ch_b;
				end
				slot_column_parity <= ~slot_column_parity;
				slot_line_active <= 1'b1;
			end
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			VGA_R_OUT <= 8'd0;
			VGA_G_OUT <= 8'd0;
			VGA_B_OUT <= 8'd0;
			VGA_HS_OUT <= 1'b1;
			VGA_VS_OUT <= 1'b1;
			VGA_HBLANK_OUT <= 1'b1;
			VGA_VBLANK_OUT <= 1'b1;
		end else if (ce_pix) begin
			VGA_R_OUT <= selected_r;
			VGA_G_OUT <= selected_g;
			VGA_B_OUT <= selected_b;
			VGA_HS_OUT <= selected_hs;
			VGA_VS_OUT <= selected_vs;
			VGA_HBLANK_OUT <= selected_hblank;
			VGA_VBLANK_OUT <= selected_vblank;
		end
	end

endmodule
