// ============================================================================
// CRT profile resolver.
// written 2026 by Videodr0me
//
// Resolves the selected profile into the settings used by vfb_top.
// Fixed profiles vary by resolution; Custom 1 and Custom 2 use their
// editable OSD values.
// ============================================================================

module vfb_profile_resolver (
	input  logic [2:0]  profile,
	input  logic [11:0] fb_height,
	input  logic        game_is_deluxe,
	input  logic        game_is_lander,

	input  logic [2:0]  off_dot_mode,
	input  logic [1:0]  off_tonemapping,
	input  logic [1:0]  off_inter_frame_decay,
	input  logic [1:0]  off_intra_frame_decay,
	input  logic [27:0] custom1_settings,
	input  logic [27:0] custom2_settings,
	input  logic        custom_artwork_enable,
	input  logic  [2:0] custom_artwork_blend,

	output logic [2:0]  dot_mode,
	output logic [1:0]  tonemapping,
	output logic [2:0]  bloom_width,
	output logic [2:0]  bloom_curve,
	output logic [2:0]  halo_filter,
	output logic [2:0]  halo_curve,
	output logic [1:0]  halo_spread,
	output logic [1:0]  halo_knee,
	output logic [1:0]  inter_frame_decay,
	output logic [1:0]  intra_frame_decay,
	output logic [2:0]  presentation_color,
	output logic        full_bypass,
	output logic        artwork_enable,
	output logic [2:0]  artwork_blend
);

	localparam logic [2:0] PROFILE_OFF        = 3'd0;
	localparam logic [2:0] PROFILE_TOUCH      = 3'd1;
	localparam logic [2:0] PROFILE_TYPICAL    = 3'd2;
	localparam logic [2:0] PROFILE_OVERDRIVEN = 3'd3;
	localparam logic [2:0] PROFILE_ULTRAVIOLET = 3'd5;
	localparam logic [2:0] PROFILE_RED_ALERT   = 3'd4;
	localparam logic [2:0] PROFILE_CUSTOM1    = 3'd6;
	localparam logic [2:0] PROFILE_CUSTOM2    = 3'd7;

	localparam logic [2:0] DOT_2X  = 3'd0;
	localparam logic [2:0] DOT_25X = 3'd1;
	localparam logic [2:0] DOT_3X  = 3'd2;
	localparam logic [2:0] DOT_4X  = 3'd3;
	localparam logic [2:0] DOT_5X  = 3'd4;
	localparam logic [2:0] DOT_1X  = 3'd5;
	localparam logic [2:0] DOT_15X = 3'd6;

	localparam logic [1:0] TONE_LINEAR1 = 2'd0;
	localparam logic [1:0] TONE_LINEAR2 = 2'd1;
	localparam logic [1:0] TONE_BRIGHT  = 2'd2;
	localparam logic [1:0] TONE_OFF     = 2'd3;

	localparam logic [2:0] BLOOM_OFF    = 3'd0;
	localparam logic [2:0] BLOOM_THIN   = 3'd1;
	localparam logic [2:0] BLOOM_TIGHT  = 3'd2;
	localparam logic [2:0] BLOOM_SOFT   = 3'd3;
	localparam logic [2:0] BLOOM_NORMAL = 3'd4;
	localparam logic [2:0] BLOOM_BROAD  = 3'd5;
	localparam logic [2:0] BLOOM_WIDE_M = 3'd6;
	localparam logic [2:0] BLOOM_WIDE   = 3'd7;

	localparam logic [2:0] CURVE_MINIMAL  = 3'd0;
	localparam logic [2:0] CURVE_MIN_PLUS = 3'd1;
	localparam logic [2:0] CURVE_MILD     = 3'd2;
	localparam logic [2:0] CURVE_MILD_P   = 3'd3;
	localparam logic [2:0] CURVE_MODERATE = 3'd4;
	localparam logic [2:0] CURVE_MOD_PLUS = 3'd5;
	localparam logic [2:0] CURVE_STRONG_M = 3'd6;
	localparam logic [2:0] CURVE_STRONG   = 3'd7;

	localparam logic [2:0] HALO_OFF  = 3'd0;
	localparam logic [2:0] HALO_025X = 3'd1;
	localparam logic [2:0] HALO_033X = 3'd2;
	localparam logic [2:0] HALO_050X = 3'd3;
	localparam logic [2:0] HALO_075X = 3'd4;
	localparam logic [2:0] HALO_100X = 3'd5;
	localparam logic [2:0] HALO_125X = 3'd6;
	localparam logic [2:0] HALO_150X = 3'd7;

	localparam logic [1:0] SPREAD_ORIGINAL = 2'd0;
	localparam logic [1:0] SPREAD_WIDE1    = 2'd1;
	localparam logic [1:0] SPREAD_WIDE2    = 2'd2;
	localparam logic [1:0] SPREAD_WIDE3    = 2'd3;
	localparam logic [1:0] KNEE_OFF        = 2'd0;
	localparam logic [1:0] KNEE_8          = 2'd1;
	localparam logic [1:0] KNEE_16         = 2'd2;
	localparam logic [1:0] KNEE_24         = 2'd3;

	localparam logic [1:0] INTER_OFF    = 2'd0;
	localparam logic [1:0] INTER_SHORT  = 2'd1;
	localparam logic [1:0] INTER_MEDIUM = 2'd2;
	localparam logic [1:0] INTER_LONG   = 2'd3;

	localparam logic [1:0] INTRA_OFF   = 2'd0;
	localparam logic [1:0] INTRA_LUT_A = 2'd1;
	localparam logic [1:0] INTRA_LUT_B = 2'd2;
	localparam logic [1:0] INTRA_LUT_C = 2'd3;

	localparam logic [2:0] COLOR_WHITE       = 3'd0;
	localparam logic [2:0] COLOR_DELUXE_BLUE = 3'd1;
	localparam logic [2:0] COLOR_LUNAR       = 3'd2;
	localparam logic [2:0] COLOR_RED         = 3'd3;
	localparam logic [2:0] COLOR_PURPLE      = 3'd4;
	localparam logic [2:0] COLOR_CYAN        = 3'd5;
	localparam logic [2:0] COLOR_YELLOW      = 3'd6;

	localparam logic       ARTWORK_OFF = 1'b0;
	localparam logic       ARTWORK_ON  = 1'b1;
	localparam logic [2:0] ARTWORK_BLEND_0  = 3'd0;
	localparam logic [2:0] ARTWORK_BLEND_P1 = 3'd1;
	localparam logic [2:0] ARTWORK_BLEND_P2 = 3'd2;
	localparam logic [2:0] ARTWORK_BLEND_P3 = 3'd3;
	localparam logic [2:0] ARTWORK_BLEND_M4 = 3'd4;
	localparam logic [2:0] ARTWORK_BLEND_M3 = 3'd5;
	localparam logic [2:0] ARTWORK_BLEND_M2 = 3'd6;
	localparam logic [2:0] ARTWORK_BLEND_M1 = 3'd7;

	function automatic logic [31:0] pack_settings;
		input logic       artwork_enable_i;
		input logic [2:0] artwork_blend_i;
		input logic [2:0] dot_i;
		input logic [1:0] tone_i;
		input logic [2:0] bloom_width_i;
		input logic [2:0] bloom_curve_i;
		input logic [2:0] halo_i;
		input logic [2:0] halo_curve_i;
		input logic [1:0] halo_spread_i;
		input logic [1:0] halo_knee_i;
		input logic [1:0] inter_decay_i;
		input logic [1:0] intra_decay_i;
		input logic [2:0] color_i;
		begin
			pack_settings = {
				artwork_enable_i,
				artwork_blend_i,
				halo_knee_i,
				dot_i,
				tone_i,
				bloom_width_i,
				bloom_curve_i,
				halo_i,
				halo_curve_i,
				halo_spread_i,
				inter_decay_i,
				intra_decay_i,
				color_i
			};
		end
	endfunction

	function automatic logic [31:0] fixed_deluxe_480p;
		input logic [2:0] profile_i;
		begin
			case (profile_i)
				PROFILE_TOUCH: fixed_deluxe_480p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_2X, TONE_LINEAR2, BLOOM_OFF, CURVE_MINIMAL,
					HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, INTER_OFF, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_TYPICAL: fixed_deluxe_480p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_2X, TONE_LINEAR2, BLOOM_THIN, CURVE_MILD_P,
					HALO_075X, CURVE_MILD, SPREAD_ORIGINAL, KNEE_16, INTER_SHORT, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_OVERDRIVEN: fixed_deluxe_480p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_25X, TONE_BRIGHT, BLOOM_THIN, CURVE_MILD_P,
					HALO_100X, CURVE_MODERATE, SPREAD_ORIGINAL, KNEE_16, INTER_MEDIUM, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_ULTRAVIOLET: fixed_deluxe_480p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_OFF, INTER_LONG, INTRA_LUT_C,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_deluxe_480p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG_M,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE1, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_deluxe_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_0,
					DOT_1X, TONE_LINEAR1, BLOOM_OFF, CURVE_MINIMAL,
					HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, INTER_OFF, INTRA_OFF,
					COLOR_DELUXE_BLUE);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_deluxe_240p;
		input logic [2:0] profile_i;
		begin
			case (profile_i)
				PROFILE_TOUCH: fixed_deluxe_240p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_2X, TONE_LINEAR2, BLOOM_OFF, CURVE_MINIMAL,
					HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, INTER_OFF, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_TYPICAL: fixed_deluxe_240p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_2X, TONE_LINEAR2, BLOOM_THIN, CURVE_MILD_P,
					HALO_075X, CURVE_MILD, SPREAD_ORIGINAL, KNEE_16, INTER_SHORT, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_OVERDRIVEN: fixed_deluxe_240p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_25X, TONE_BRIGHT, BLOOM_THIN, CURVE_MILD_P,
					HALO_100X, CURVE_MODERATE, SPREAD_ORIGINAL, KNEE_16, INTER_MEDIUM, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_ULTRAVIOLET: fixed_deluxe_240p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_OFF, INTER_LONG, INTRA_LUT_C,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_deluxe_240p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG_M,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE1, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_deluxe_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_0,
					DOT_1X, TONE_LINEAR1, BLOOM_OFF, CURVE_MINIMAL,
					HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, INTER_OFF, INTRA_OFF,
					COLOR_DELUXE_BLUE);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_deluxe_720p;
		input logic [2:0] profile_i;
		begin
			case (profile_i)
				PROFILE_TOUCH: fixed_deluxe_720p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_4X, TONE_BRIGHT, BLOOM_THIN, CURVE_MODERATE,
					HALO_125X, CURVE_MINIMAL, SPREAD_WIDE1, KNEE_8, INTER_OFF, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_TYPICAL: fixed_deluxe_720p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_4X, TONE_BRIGHT, BLOOM_THIN, CURVE_MOD_PLUS,
					HALO_150X, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_16, INTER_SHORT, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_OVERDRIVEN: fixed_deluxe_720p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_MILD_P,
					HALO_150X, CURVE_MILD, SPREAD_ORIGINAL, KNEE_8, INTER_MEDIUM, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_ULTRAVIOLET: fixed_deluxe_720p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_WIDE, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_ORIGINAL, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_deluxe_720p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_SOFT, CURVE_MODERATE,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE1, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_deluxe_720p = fixed_deluxe_480p(profile_i);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_deluxe_1080p;
		input logic [2:0] profile_i;
		begin
			case (profile_i)
				PROFILE_TOUCH: fixed_deluxe_1080p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_4X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_MILD_P,
					HALO_125X, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_8, INTER_OFF, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_TYPICAL: fixed_deluxe_1080p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_MODERATE,
					HALO_150X, CURVE_STRONG_M, SPREAD_WIDE2, KNEE_8, INTER_SHORT, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_OVERDRIVEN: fixed_deluxe_1080p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_NORMAL, CURVE_MILD,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_24, INTER_MEDIUM, INTRA_OFF,
					COLOR_DELUXE_BLUE);
				PROFILE_ULTRAVIOLET: fixed_deluxe_1080p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_WIDE, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_ORIGINAL, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_deluxe_1080p = pack_settings(
					ARTWORK_ON, ARTWORK_BLEND_0,
					DOT_5X, TONE_BRIGHT, BLOOM_BROAD, CURVE_MODERATE,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_deluxe_1080p = fixed_deluxe_480p(profile_i);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_asteroids_lander_480p;
		input logic [2:0] profile_i;
		input logic       lander_i;
		logic [2:0] normal_color;
		begin
			normal_color = lander_i ? COLOR_LUNAR : COLOR_WHITE;
			case (profile_i)
				PROFILE_TOUCH: fixed_asteroids_lander_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_2X, TONE_LINEAR1, BLOOM_THIN, CURVE_MILD_P,
					HALO_033X, CURVE_MILD_P, SPREAD_WIDE1, KNEE_OFF, INTER_OFF, INTRA_OFF,
					normal_color);
				PROFILE_TYPICAL: fixed_asteroids_lander_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_2X, TONE_LINEAR1, BLOOM_THIN, CURVE_MILD_P,
					HALO_050X, CURVE_MILD_P, SPREAD_WIDE3, KNEE_OFF, INTER_SHORT, INTRA_OFF,
					normal_color);
				PROFILE_OVERDRIVEN: fixed_asteroids_lander_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_25X, TONE_LINEAR1, BLOOM_TIGHT, CURVE_MILD,
					HALO_050X, CURVE_MILD, SPREAD_WIDE3, KNEE_OFF,
					lander_i ? INTER_SHORT : INTER_MEDIUM,
					lander_i ? INTRA_LUT_C : INTRA_OFF, normal_color);
				PROFILE_ULTRAVIOLET: fixed_asteroids_lander_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_OFF, INTER_LONG, INTRA_LUT_C,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_asteroids_lander_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG_M,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE1, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_asteroids_lander_480p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_1X, TONE_LINEAR1, BLOOM_OFF, CURVE_MINIMAL,
					HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, INTER_OFF, INTRA_OFF,
					normal_color);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_asteroids_lander_240p;
		input logic [2:0] profile_i;
		input logic       lander_i;
		logic [2:0] normal_color;
		begin
			normal_color = lander_i ? COLOR_LUNAR : COLOR_WHITE;
			case (profile_i)
				PROFILE_TOUCH: fixed_asteroids_lander_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_2X, TONE_LINEAR1, BLOOM_THIN, CURVE_MILD_P,
					HALO_033X, CURVE_MILD_P, SPREAD_WIDE1, KNEE_OFF, INTER_OFF, INTRA_OFF,
					normal_color);
				PROFILE_TYPICAL: fixed_asteroids_lander_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_2X, TONE_LINEAR1, BLOOM_THIN, CURVE_MILD_P,
					HALO_050X, CURVE_MILD_P, SPREAD_WIDE3, KNEE_OFF, INTER_SHORT, INTRA_OFF,
					normal_color);
				PROFILE_OVERDRIVEN: fixed_asteroids_lander_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_25X, TONE_LINEAR1, BLOOM_TIGHT, CURVE_MILD,
					HALO_050X, CURVE_MILD, SPREAD_WIDE3, KNEE_OFF,
					lander_i ? INTER_SHORT : INTER_MEDIUM,
					lander_i ? INTRA_LUT_C : INTRA_OFF, normal_color);
				PROFILE_ULTRAVIOLET: fixed_asteroids_lander_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_OFF, INTER_LONG, INTRA_LUT_C,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_asteroids_lander_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_BRIGHT, BLOOM_TIGHT, CURVE_STRONG_M,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE1, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_asteroids_lander_240p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_1X, TONE_LINEAR1, BLOOM_OFF, CURVE_MINIMAL,
					HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, INTER_OFF, INTRA_OFF,
					normal_color);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_asteroids_lander_720p;
		input logic [2:0] profile_i;
		input logic       lander_i;
		logic [2:0] normal_color;
		begin
			normal_color = lander_i ? COLOR_LUNAR : COLOR_WHITE;
			case (profile_i)
				PROFILE_TOUCH: fixed_asteroids_lander_720p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_25X, TONE_LINEAR1, BLOOM_THIN, CURVE_MILD_P,
					HALO_025X, CURVE_MILD_P, SPREAD_WIDE1, KNEE_OFF, INTER_OFF, INTRA_OFF,
					normal_color);
				PROFILE_TYPICAL: fixed_asteroids_lander_720p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_LINEAR1, BLOOM_TIGHT, CURVE_MILD,
					HALO_033X, CURVE_MILD, SPREAD_WIDE1, KNEE_OFF, INTER_SHORT, INTRA_OFF,
					normal_color);
				PROFILE_OVERDRIVEN: fixed_asteroids_lander_720p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_LINEAR1, BLOOM_NORMAL, CURVE_MINIMAL,
					HALO_050X, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF,
					lander_i ? INTER_SHORT : INTER_MEDIUM,
					lander_i ? INTRA_LUT_C : INTRA_OFF, normal_color);
				PROFILE_ULTRAVIOLET: fixed_asteroids_lander_720p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_5X, TONE_BRIGHT, BLOOM_WIDE, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_ORIGINAL, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_asteroids_lander_720p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_5X, TONE_BRIGHT, BLOOM_SOFT, CURVE_MODERATE,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE1, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_asteroids_lander_720p =
					fixed_asteroids_lander_480p(profile_i, lander_i);
			endcase
		end
	endfunction

	function automatic logic [31:0] fixed_asteroids_lander_1080p;
		input logic [2:0] profile_i;
		input logic       lander_i;
		logic [2:0] normal_color;
		begin
			normal_color = lander_i ? COLOR_LUNAR : COLOR_WHITE;
			case (profile_i)
				PROFILE_TOUCH: fixed_asteroids_lander_1080p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_LINEAR1, BLOOM_TIGHT, CURVE_MILD_P,
					HALO_025X, CURVE_MILD_P, SPREAD_WIDE1, KNEE_OFF, INTER_OFF, INTRA_OFF,
					normal_color);
				PROFILE_TYPICAL: fixed_asteroids_lander_1080p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_LINEAR1, BLOOM_SOFT, CURVE_MILD,
					HALO_033X, CURVE_MILD, SPREAD_WIDE1, KNEE_OFF, INTER_SHORT, INTRA_OFF,
					normal_color);
				PROFILE_OVERDRIVEN: fixed_asteroids_lander_1080p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_3X, TONE_LINEAR1, BLOOM_NORMAL, CURVE_MILD,
					HALO_050X, CURVE_MILD, SPREAD_WIDE1, KNEE_OFF,
					lander_i ? INTER_SHORT : INTER_MEDIUM,
					lander_i ? INTRA_LUT_C : INTRA_OFF, normal_color);
				PROFILE_ULTRAVIOLET: fixed_asteroids_lander_1080p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_5X, TONE_BRIGHT, BLOOM_WIDE, CURVE_STRONG,
					HALO_150X, CURVE_STRONG, SPREAD_ORIGINAL, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_PURPLE);
				PROFILE_RED_ALERT: fixed_asteroids_lander_1080p = pack_settings(
					ARTWORK_OFF, ARTWORK_BLEND_M2,
					DOT_5X, TONE_BRIGHT, BLOOM_BROAD, CURVE_MODERATE,
					HALO_150X, CURVE_STRONG, SPREAD_WIDE2, KNEE_OFF, INTER_LONG, INTRA_LUT_A,
					COLOR_RED);
				default: fixed_asteroids_lander_1080p =
					fixed_asteroids_lander_480p(profile_i, lander_i);
			endcase
		end
	endfunction

	logic [31:0] selected_settings;

	always_comb begin
		unique case (profile)
			PROFILE_OFF: selected_settings = pack_settings(
				ARTWORK_OFF, ARTWORK_BLEND_M2,
				off_dot_mode, off_tonemapping, BLOOM_OFF, CURVE_MINIMAL,
				HALO_OFF, CURVE_MINIMAL, SPREAD_ORIGINAL, KNEE_OFF, off_inter_frame_decay,
				off_intra_frame_decay,
				game_is_lander ? COLOR_LUNAR :
				game_is_deluxe ? COLOR_DELUXE_BLUE : COLOR_WHITE);
			PROFILE_CUSTOM1: selected_settings = {
				custom_artwork_enable, custom_artwork_blend, custom1_settings
			};
			PROFILE_CUSTOM2: selected_settings = {
				custom_artwork_enable, custom_artwork_blend, custom2_settings
			};
			default: begin
				if (game_is_deluxe) begin
					if (fb_height >= 12'd1000)
						selected_settings = fixed_deluxe_1080p(profile);
					else if (fb_height >= 12'd700)
						selected_settings = fixed_deluxe_720p(profile);
					else if (fb_height >= 12'd400)
						selected_settings = fixed_deluxe_480p(profile);
					else
						selected_settings = fixed_deluxe_240p(profile);
				end else begin
					if (fb_height >= 12'd1000)
						selected_settings = fixed_asteroids_lander_1080p(
							profile, game_is_lander);
					else if (fb_height >= 12'd700)
						selected_settings = fixed_asteroids_lander_720p(
							profile, game_is_lander);
					else if (fb_height >= 12'd400)
						selected_settings = fixed_asteroids_lander_480p(
							profile, game_is_lander);
					else
						selected_settings = fixed_asteroids_lander_240p(
							profile, game_is_lander);
				end
			end
		endcase

		dot_mode       = selected_settings[25:23];
		tonemapping    = selected_settings[22:21];
		bloom_width    = selected_settings[20:18];
		bloom_curve    = selected_settings[17:15];
		halo_filter    = selected_settings[14:12];
		halo_curve     = selected_settings[11:9];
		halo_spread    = selected_settings[8:7];
		halo_knee      = selected_settings[27:26];
		inter_frame_decay = selected_settings[6:5];
		intra_frame_decay = selected_settings[4:3];
		presentation_color = selected_settings[2:0];
		artwork_enable = selected_settings[31];
		artwork_blend  = selected_settings[30:28];
		full_bypass = (profile == PROFILE_OFF);
	end

endmodule
