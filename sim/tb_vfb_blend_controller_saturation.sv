`timescale 1ns/1ps

// Reproduce the saturated Blend ownership state seen on hardware: one display,
// one retained raw-history frame, and all remaining buffers queued as DRAWN.
// With no CLEAN composition target or DIRTY buffer, the controller must drop an
// old raw frame even though composition is idle, then clear and reuse it.
module tb_vfb_blend_controller_saturation;
	logic clk = 0;
	always #4 clk = ~clk;

	logic reset = 1;
	logic clear_done = 0;
	wire flush_req, clear_req, compose_req, has_draw_buf;
	wire [2:0] clear_buf_idx;
	wire raw_frame_dropped;

	vfb_buffer_controller dut (
		.clk_sys(clk), .reset(reset),
		.BUFFER_MODE(2'd0), .inter_frame_mode(2'd1),
		.eof_token_popped(1'b0), .vbl_swap_req(1'b0),
		.flush_req(flush_req), .flush_done(1'b0),
		.clear_req(clear_req), .clear_buf_idx(clear_buf_idx),
		.clear_done(clear_done),
		.compose_req(compose_req), .compose_source_buf(),
		.compose_raw_buf(), .compose_target_buf(), .compose_has_source(),
		.compose_source_is_composed(), .compose_done(1'b0),
		.buf_draw(), .buf_display_out(), .display_valid(),
		.display_is_composed(), .has_draw_buf(has_draw_buf),
		.raw_frame_dropped(raw_frame_dropped), .raw_frame_dropped_buf(),
		.readout_frame_start()
	);

	logic saw_drop = 0;
	always_ff @(posedge clk) begin
		clear_done <= clear_req;
		if (raw_frame_dropped)
			saw_drop <= 1;
	end

	initial begin
		repeat (4) @(posedge clk);
		reset <= 0;
		@(negedge clk);

		// Seed the terminal ownership mix directly.
		dut.buf_state[0] = dut.ST_DISPLAY;
		dut.buf_state[1] = dut.ST_RAW_HISTORY;
		dut.buf_state[2] = dut.ST_DRAWN;
		dut.buf_state[3] = dut.ST_DRAWN;
		dut.buf_state[4] = dut.ST_DRAWN;
		dut.compose_active = 1'b0;

		repeat (20) @(posedge clk);
		if (!saw_drop)
			$fatal(1, "saturated idle Blend state did not drop a raw frame");
		if (!has_draw_buf)
			$fatal(1, "saturated idle Blend state did not recover a draw buffer");
		$display("PASS: saturated idle Blend ownership recovers");
		$finish;
	end
endmodule
