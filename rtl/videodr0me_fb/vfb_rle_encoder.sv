// ============================================================================
// RGB24 line-local RLE16 encoder.
// written 2026 by Videodr0me
//
// Implemented RLE16 control table. Each output token is one 16-bit word;
// full RGB literals use two tokens:
//   0x0: full RGB literal, word0 [11:4]=R [3:0]=count-1,
//        word1 [15:8]=G [7:0]=B
//   0x1..0x7: masked intensity run, opcode bits are {R,G,B} mask,
//        [11:4]=intensity [3:0]=count-1
//   0x8: repeat previous decoded RGB, [11:0]=count-1
//   0x9..0xE: main-ceiling spill run for masks 001..110:
//        opcode bits [2:0] are {R,G,B} main-channel mask,
//        channels with mask bit 1 decode to 232,
//        channels with mask bit 0 decode to [11:4] spill intensity,
//        [3:0]=count-1. Examples:
//        mask 110, spill 49 => RGB=(232,232,49)
//        mask 001, spill 129 => RGB=(129,129,232)
//   0xF: black run, [11:0]=count-1. Odd-length lines are padded with 0xF000;
//        the descriptor excludes it.
//
// The previous decoded RGB is reset to black at each line boundary.
// The encoder therefore terminates every line independently and emits token_eol
// on the final real word of the line.
// ============================================================================

module vfb_rle_encoder (
	input  logic        clk_sys,
	input  logic        reset,

	input  logic        pixel_valid,
	input  logic [23:0] rgb_in,
	input  logic        line_end,

	output logic        token_valid,
	input  logic        token_ready,
	output logic [15:0] token_data,
	output logic        token_eol,

	output logic        overflow
);

	localparam integer RUN_FIFO_DEPTH = 16;
	localparam integer RUN_FIFO_AW = 4;
	localparam integer RUN_DESCRIPTOR_WIDTH = 2 + 24;
	localparam integer RUN_FIFO_WIDTH = 1 + 13 + RUN_DESCRIPTOR_WIDTH;
	localparam logic [7:0] SPILL_MAIN_CEIL = 8'd232;

	typedef enum logic [1:0] {
		RUN_BLACK,
		RUN_INTENSITY,
		RUN_SPILL,
		RUN_LITERAL
	} run_kind_t;

	typedef enum logic [2:0] {
		EMIT_IDLE,
		EMIT_BLACK,
		EMIT_INTENSITY,
		EMIT_SPILL,
		EMIT_LITERAL0,
		EMIT_LITERAL1,
		EMIT_REPEAT
	} emit_state_t;

	logic        run_valid;
	logic [23:0] run_rgb;
	logic [RUN_DESCRIPTOR_WIDTH-1:0] run_descriptor;
	logic [12:0] run_count;
	logic        input_pixel_valid;
	logic [23:0] input_rgb;
	logic        input_line_end;

	// Registered run state decouples detection from output.
	(* ramstyle = "logic" *) logic [RUN_FIFO_WIDTH-1:0] run_fifo_entry [0:RUN_FIFO_DEPTH-1];
	logic [RUN_FIFO_AW:0] run_fifo_used;
	logic [RUN_FIFO_AW-1:0] run_fifo_rd_ptr;
	logic [RUN_FIFO_AW-1:0] run_fifo_wr_ptr;
	logic                         pending_valid;
	logic [RUN_FIFO_WIDTH-1:0]    pending_entry;
	logic                         prefetch_valid;
	logic [RUN_FIFO_WIDTH-1:0]    prefetch_entry;

	emit_state_t emit_state;
	logic [23:0] emit_payload;
	logic [12:0] emit_count;
	logic [12:0] emit_repeat_remaining;
	logic        emit_eol;
	logic [3:0]  emit_literal_count_m1;

	function automatic logic is_black(input logic [23:0] rgb);
		is_black = (rgb == 24'd0);
	endfunction

	function automatic logic is_masked_intensity(input logic [23:0] rgb);
		logic [7:0] r;
		logic [7:0] g;
		logic [7:0] b;
		logic [7:0] intensity;
		logic       valid;
		logic       mismatch;
		begin
			r = rgb[23:16];
			g = rgb[15:8];
			b = rgb[7:0];
			valid = 1'b0;
			mismatch = 1'b0;
			intensity = 8'd0;

			if (r != 0) begin
				intensity = r;
				valid = 1'b1;
			end
			if (g != 0) begin
				if (!valid) begin
					intensity = g;
					valid = 1'b1;
				end else if (g != intensity)
					mismatch = 1'b1;
			end
			if (b != 0) begin
				if (!valid) begin
					intensity = b;
					valid = 1'b1;
				end else if (b != intensity)
					mismatch = 1'b1;
			end
			is_masked_intensity = valid && !mismatch;
		end
	endfunction

	function automatic [2:0] rgb_mask(input logic [23:0] rgb);
		rgb_mask = {
			(rgb[23:16] != 8'd0),
			(rgb[15:8]  != 8'd0),
			(rgb[7:0]   != 8'd0)
		};
	endfunction

	function automatic [2:0] spill_main_mask(input logic [23:0] rgb);
		spill_main_mask = {
			(rgb[23:16] == SPILL_MAIN_CEIL),
			(rgb[15:8]  == SPILL_MAIN_CEIL),
			(rgb[7:0]   == SPILL_MAIN_CEIL)
		};
	endfunction

	function automatic [7:0] spill_intensity(input logic [23:0] rgb);
		begin
			if (rgb[23:16] != SPILL_MAIN_CEIL)
				spill_intensity = rgb[23:16];
			else if (rgb[15:8] != SPILL_MAIN_CEIL)
				spill_intensity = rgb[15:8];
			else
				spill_intensity = rgb[7:0];
		end
	endfunction

	function automatic logic is_main_ceiling_spill(input logic [23:0] rgb);
		logic [2:0] mask;
		logic [7:0] spill;
		logic       valid;
		logic       mismatch;
		begin
			mask = spill_main_mask(rgb);
			valid = 1'b0;
			mismatch = 1'b0;
			spill = 8'd0;

			if (mask != 3'b000 && mask != 3'b111) begin
				if (rgb[23:16] != SPILL_MAIN_CEIL) begin
					spill = rgb[23:16];
					valid = 1'b1;
				end
				if (rgb[15:8] != SPILL_MAIN_CEIL) begin
					if (!valid) begin
						spill = rgb[15:8];
						valid = 1'b1;
					end else if (rgb[15:8] != spill)
						mismatch = 1'b1;
				end
				if (rgb[7:0] != SPILL_MAIN_CEIL) begin
					if (!valid) begin
						spill = rgb[7:0];
						valid = 1'b1;
					end else if (rgb[7:0] != spill)
						mismatch = 1'b1;
				end
			end

			is_main_ceiling_spill =
				(mask != 3'b000) && (mask != 3'b111) && !mismatch;
		end
	endfunction

	function automatic [7:0] masked_intensity(input logic [23:0] rgb);
		begin
			if (rgb[23:16] != 8'd0)
				masked_intensity = rgb[23:16];
			else if (rgb[15:8] != 8'd0)
				masked_intensity = rgb[15:8];
			else
				masked_intensity = rgb[7:0];
		end
	endfunction

	function automatic logic [RUN_DESCRIPTOR_WIDTH-1:0] classify_run(
		input logic [23:0] rgb
	);
		begin
			if (is_black(rgb))
				classify_run = {RUN_BLACK, 24'd0};
			else if (is_masked_intensity(rgb))
				classify_run = {
					RUN_INTENSITY,
					13'd0,
					rgb_mask(rgb),
					masked_intensity(rgb)
				};
			else if (is_main_ceiling_spill(rgb))
				classify_run = {
					RUN_SPILL,
					13'd0,
					spill_main_mask(rgb),
					spill_intensity(rgb)
				};
			else
				classify_run = {RUN_LITERAL, rgb};
		end
	endfunction

	function automatic [11:0] count_m1_12(input logic [12:0] count);
		count_m1_12 = count[11:0] - 12'd1;
	endfunction

	function automatic [3:0] count_m1_4(input logic [4:0] count);
		count_m1_4 = count[3:0] - 4'd1;
	endfunction

	wire emit_can_write = !token_valid || token_ready;
	wire emit_busy = (emit_state != EMIT_IDLE);
	wire emit_finishes_now =
		emit_can_write &&
		((emit_state == EMIT_BLACK && emit_repeat_remaining <= 13'd4096) ||
		 (emit_state == EMIT_INTENSITY &&
		  emit_repeat_remaining == 13'd0) ||
		 (emit_state == EMIT_SPILL &&
		  emit_repeat_remaining == 13'd0) ||
		 (emit_state == EMIT_LITERAL1 &&
		  emit_repeat_remaining == 13'd0) ||
		 (emit_state == EMIT_REPEAT &&
		  emit_repeat_remaining <= 13'd4096));
	wire emit_available_for_new = !emit_busy || emit_finishes_now;
	wire [4:0] first_count =
		(emit_count > 13'd16) ? 5'd1 : {1'b0, emit_count[3:0]};

	wire run_fifo_empty = (run_fifo_used == 0);
	wire run_fifo_full = (run_fifo_used == RUN_FIFO_DEPTH);
	wire run_fifo_pop = !prefetch_valid && !run_fifo_empty;
	wire [RUN_FIFO_WIDTH-1:0] run_fifo_head =
		run_fifo_entry[run_fifo_rd_ptr];
	wire start_prefetch = emit_available_for_new && prefetch_valid;
	wire start_fifo_head =
		emit_available_for_new && !prefetch_valid && run_fifo_pop;
	wire run_fifo_can_push = !run_fifo_full || run_fifo_pop;
	wire run_fifo_push = pending_valid && run_fifo_can_push;
	wire pixel_extends_run =
		input_pixel_valid && run_valid && input_rgb == run_rgb &&
		run_count < 13'd4096;
	wire pixel_finishes_run =
		input_pixel_valid && run_valid && !pixel_extends_run;
	wire line_finishes_run = input_line_end && run_valid;
	wire [RUN_FIFO_WIDTH-1:0] completed_run_entry = {
		line_finishes_run,
		run_count,
		run_descriptor
	};
	wire run_close_request =
		pixel_finishes_run || line_finishes_run;
	wire pending_ready = !pending_valid || run_fifo_can_push;
	wire run_close_accept = run_close_request && pending_ready;

	wire start_emit = start_prefetch || start_fifo_head;
	wire [RUN_FIFO_WIDTH-1:0] start_entry =
		prefetch_valid ? prefetch_entry : run_fifo_head;
	wire        start_eol = start_entry[39];
	wire [12:0] start_count = start_entry[38:26];
	wire [1:0]  start_kind = start_entry[25:24];
	wire [23:0] start_payload = start_entry[23:0];
	wire [4:0] start_literal_count =
		(start_count > 13'd16) ? 5'd1 : {1'b0, start_count[3:0]};

	emit_state_t start_state;
	logic [12:0] start_repeat_remaining;
	always_comb begin
		start_state = EMIT_LITERAL0;
		start_repeat_remaining =
			(start_count > 13'd16) ? start_count - 13'd1 : 13'd0;
		case (start_kind)
			RUN_BLACK: begin
				start_state = EMIT_BLACK;
				start_repeat_remaining = start_count;
			end
			RUN_INTENSITY: start_state = EMIT_INTENSITY;
			RUN_SPILL: start_state = EMIT_SPILL;
			default: start_state = EMIT_LITERAL0;
		endcase
	end

	always_ff @(posedge clk_sys) begin
		if (reset) begin
			token_valid <= 1'b0;
			token_data <= 16'd0;
			token_eol <= 1'b0;
			run_valid <= 1'b0;
			run_rgb <= 24'd0;
			run_descriptor <= '0;
			run_count <= 13'd0;
			input_pixel_valid <= 1'b0;
			input_rgb <= 24'd0;
			input_line_end <= 1'b0;
			run_fifo_used <= '0;
			run_fifo_rd_ptr <= '0;
			run_fifo_wr_ptr <= '0;
			pending_valid <= 1'b0;
			pending_entry <= '0;
			prefetch_valid <= 1'b0;
			prefetch_entry <= '0;
			emit_state <= EMIT_IDLE;
			emit_payload <= 24'd0;
			emit_count <= 13'd0;
			emit_repeat_remaining <= 13'd0;
			emit_eol <= 1'b0;
			emit_literal_count_m1 <= 4'd0;
			overflow <= 1'b0;
		end else begin
			input_pixel_valid <= pixel_valid;
			input_rgb <= rgb_in;
			input_line_end <= line_end;

			if (token_valid && token_ready)
				token_valid <= 1'b0;

			if (emit_busy && emit_can_write) begin
				token_valid <= 1'b1;
				case (emit_state)
					EMIT_BLACK: begin
						if (emit_repeat_remaining > 13'd4096) begin
							token_data <= {4'hf, 12'hfff};
							token_eol <= 1'b0;
							emit_repeat_remaining <=
								emit_repeat_remaining - 13'd4096;
						end else begin
							token_data <= {
								4'hf,
								count_m1_12(emit_repeat_remaining)
							};
							token_eol <= emit_eol;
							emit_state <= EMIT_IDLE;
						end
					end

					EMIT_INTENSITY: begin
						token_data <= {
							1'b0,
							emit_payload[10:8],
							emit_payload[7:0],
							count_m1_4(first_count)
						};
						token_eol <=
							(emit_repeat_remaining == 13'd0) &&
							emit_eol;
						if (emit_repeat_remaining != 13'd0)
							emit_state <= EMIT_REPEAT;
						else
							emit_state <= EMIT_IDLE;
					end

					EMIT_SPILL: begin
						token_data <= {
							1'b1,
							emit_payload[10:8],
							emit_payload[7:0],
							count_m1_4(first_count)
						};
						token_eol <=
							(emit_repeat_remaining == 13'd0) &&
							emit_eol;
						if (emit_repeat_remaining != 13'd0)
							emit_state <= EMIT_REPEAT;
						else
							emit_state <= EMIT_IDLE;
					end

					EMIT_LITERAL0: begin
						token_data <= {
							4'h0,
							emit_payload[23:16],
							emit_literal_count_m1
						};
						token_eol <= 1'b0;
						emit_state <= EMIT_LITERAL1;
					end

					EMIT_LITERAL1: begin
						token_data <= emit_payload[15:0];
						token_eol <=
							(emit_repeat_remaining == 13'd0) &&
							emit_eol;
						if (emit_repeat_remaining != 13'd0)
							emit_state <= EMIT_REPEAT;
						else
							emit_state <= EMIT_IDLE;
					end

					EMIT_REPEAT: begin
						if (emit_repeat_remaining > 13'd4096) begin
							token_data <= {4'h8, 12'hfff};
							token_eol <= 1'b0;
							emit_repeat_remaining <=
								emit_repeat_remaining - 13'd4096;
						end else begin
							token_data <= {
								4'h8,
								count_m1_12(emit_repeat_remaining)
							};
							token_eol <= emit_eol;
							emit_state <= EMIT_IDLE;
						end
					end

					default: begin
						token_valid <= 1'b0;
						token_data <= 16'd0;
						token_eol <= 1'b0;
						emit_state <= EMIT_IDLE;
					end
				endcase
			end

			if (start_emit) begin
				emit_payload <= start_payload;
				emit_count <= start_count;
				emit_eol <= start_eol;
				emit_literal_count_m1 <=
					count_m1_4(start_literal_count);
				emit_state <= start_state;
				emit_repeat_remaining <= start_repeat_remaining;
			end

			if (start_prefetch)
				prefetch_valid <= 1'b0;

			if (run_fifo_pop) begin
				if (!start_fifo_head) begin
					prefetch_entry <= run_fifo_head;
					prefetch_valid <= 1'b1;
				end
				run_fifo_rd_ptr <= run_fifo_rd_ptr + 1'b1;
			end
			if (run_fifo_push) begin
				run_fifo_entry[run_fifo_wr_ptr] <= pending_entry;
				run_fifo_wr_ptr <= run_fifo_wr_ptr + 1'b1;
			end

			case ({run_fifo_push, run_fifo_pop})
				2'b10: run_fifo_used <= run_fifo_used + 1'b1;
				2'b01: run_fifo_used <= run_fifo_used - 1'b1;
				default: run_fifo_used <= run_fifo_used;
			endcase

			if (run_fifo_push)
				pending_valid <= 1'b0;
			if (run_close_request) begin
				if (pending_ready) begin
					pending_entry <= completed_run_entry;
					pending_valid <= 1'b1;
				end else begin
					overflow <= 1'b1;
				end
			end

			if (line_finishes_run) begin
				if (run_close_accept) begin
					run_valid <= 1'b0;
					run_count <= 13'd0;
				end
			end

			if (input_pixel_valid) begin
				if (!run_valid) begin
					run_valid <= 1'b1;
					run_rgb <= input_rgb;
					run_descriptor <= classify_run(input_rgb);
					run_count <= 13'd1;
				end else if (pixel_extends_run) begin
					run_count <= run_count + 13'd1;
				end else begin
					run_rgb <= input_rgb;
					run_descriptor <= classify_run(input_rgb);
					run_count <= 13'd1;
					run_valid <= 1'b1;
				end
			end
		end
	end

endmodule
