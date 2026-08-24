`timescale 1ns/1ps

// Sustained Blend ownership test.  Unlike the two-frame provenance test,
// frame and VBL events continue while composition and clearing are busy.
module tb_vfb_blend_controller_stress;
	parameter integer TEST_BUFFER_COUNT = 6;
	logic clk = 0;
	always #4 clk = ~clk;

	logic reset = 1;
	logic eof_token_popped = 0;
	logic vbl_swap_req = 0;
	logic flush_done = 0;
	logic clear_done = 0;
	logic compose_done = 0;
	wire flush_req;
	wire clear_req;
	wire [2:0] clear_buf_idx;
	wire compose_req;
	wire [2:0] compose_source_buf;
	wire [2:0] compose_raw_buf;
	wire [2:0] compose_target_buf;
	wire compose_has_source;
	wire compose_source_is_composed;
	wire [2:0] buf_draw;
	wire [2:0] buf_display;
	wire display_valid;
	wire display_is_composed;
	wire has_draw_buf;
	wire raw_frame_dropped;
	wire [2:0] raw_frame_dropped_buf;
	wire readout_frame_start;

	vfb_buffer_controller #(.BUFFER_COUNT(TEST_BUFFER_COUNT)) dut (
		.clk_sys(clk), .reset(reset),
		.BUFFER_MODE(2'd0), .inter_frame_mode(2'd1),
		.eof_token_popped(eof_token_popped),
		.vbl_swap_req(vbl_swap_req),
		.flush_req(flush_req), .flush_done(flush_done),
		.clear_req(clear_req), .clear_buf_idx(clear_buf_idx),
		.clear_done(clear_done),
		.compose_req(compose_req),
		.compose_source_buf(compose_source_buf),
		.compose_raw_buf(compose_raw_buf),
		.compose_target_buf(compose_target_buf),
		.compose_has_source(compose_has_source),
		.compose_source_is_composed(compose_source_is_composed),
		.compose_done(compose_done),
		.buf_draw(buf_draw), .buf_display_out(buf_display),
		.display_valid(display_valid),
		.display_is_composed(display_is_composed),
		.has_draw_buf(has_draw_buf),
		.raw_frame_dropped(raw_frame_dropped),
		.raw_frame_dropped_buf(raw_frame_dropped_buf),
		.readout_frame_start(readout_frame_start)
	);

	integer cycle = 0;
	integer clear_age = 0;
	integer compose_age = 0;
	integer compose_count = 0;
	integer display_change_count = 0;
	integer drop_count = 0;
	integer last_display_change = 0;
	logic [2:0] display_q = 0;
	logic compose_req_q = 0;

	always_ff @(posedge clk) begin
		cycle <= cycle + 1;
		eof_token_popped <= 0;
		vbl_swap_req <= 0;
		flush_done <= 0;
		clear_done <= 0;
		compose_done <= 0;
		compose_req_q <= compose_req;
		if (raw_frame_dropped)
			drop_count <= drop_count + 1;

		// Raw producers and display scanout do not wait for composition.
		if ((cycle % 40) == 7 && has_draw_buf)
			eof_token_popped <= 1;
		if ((cycle % 50) == 19)
			vbl_swap_req <= 1;

		if (flush_req)
			flush_done <= 1;

		if (clear_req) begin
			if (clear_age == 9) begin
				clear_done <= 1;
				clear_age <= 0;
			end else begin
				clear_age <= clear_age + 1;
			end
		end else begin
			clear_age <= 0;
		end

		if (compose_req && !compose_req_q) begin
			compose_age <= 1;
			if (compose_raw_buf == compose_target_buf)
				$fatal(1, "Blend raw and target alias buffer %0d", compose_raw_buf);
			if (compose_has_source &&
			    ((compose_source_buf == compose_raw_buf) ||
			     (compose_source_buf == compose_target_buf)))
				$fatal(1, "Blend source aliases raw or target");
		end else if (compose_req && compose_age == 73) begin
			compose_done <= 1;
			compose_age <= 0;
			compose_count <= compose_count + 1;
		end else if (compose_req) begin
			compose_age <= compose_age + 1;
		end else begin
			compose_age <= 0;
		end

		if (!reset && display_valid && buf_display != display_q) begin
			display_q <= buf_display;
			display_change_count <= display_change_count + 1;
			last_display_change <= cycle;
		end

		if (!reset && display_change_count > 3 &&
		    cycle - last_display_change > 500)
			$fatal(1, "Blend display ownership stalled at cycle %0d", cycle);
	end

	initial begin
		repeat (5) @(posedge clk);
		reset <= 0;
		repeat (12000) @(posedge clk);
		if (compose_count < 80)
			$fatal(1, "only %0d compositions completed", compose_count);
		if (display_change_count < 60)
			$fatal(1, "only %0d display promotions completed", display_change_count);
		if (TEST_BUFFER_COUNT == 6 && compose_count < 130)
			$fatal(1, "six-buffer scheduler completed only %0d compositions",
			       compose_count);
		if (TEST_BUFFER_COUNT == 6 && drop_count > 160)
			$fatal(1, "six-buffer scheduler dropped %0d raw frames", drop_count);
		$display("PASS: sustained Blend ownership (%0d buffers, %0d compositions, %0d promotions, %0d drops)",
		         TEST_BUFFER_COUNT, compose_count, display_change_count, drop_count);
		$finish;
	end
endmodule
