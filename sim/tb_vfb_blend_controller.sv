`timescale 1ns/1ps

module tb_vfb_blend_controller;
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

	vfb_buffer_controller dut (
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

	logic compose_req_d = 0;
	integer compose_age = 0;
	always_ff @(posedge clk) begin
		flush_done <= flush_req;
		clear_done <= clear_req;
		compose_req_d <= compose_req;
		compose_done <= 0;
		if (compose_req && !compose_req_d)
			compose_age <= 1;
		else if (compose_req && compose_age == 3) begin
			compose_done <= 1;
			compose_age <= 0;
		end else if (compose_req)
			compose_age <= compose_age + 1;
		else
			compose_age <= 0;
	end

	task automatic finish_raw_frame;
		begin
			wait (has_draw_buf);
			@(posedge clk);
			eof_token_popped <= 1;
			@(posedge clk);
			eof_token_popped <= 0;
		end
	endtask

	task automatic present_composite(input logic [2:0] expected);
		begin
			wait (!compose_req);
			@(posedge clk);
			vbl_swap_req <= 1;
			@(posedge clk);
			vbl_swap_req <= 0;
			repeat (3) @(posedge clk);
			if (buf_display !== expected)
				$fatal(1, "display %0d, expected target %0d", buf_display, expected);
		end
	endtask

	logic [2:0] raw1, raw2, target1, target2;
	initial begin
		repeat (4) @(posedge clk);
		reset <= 0;

		finish_raw_frame();
		wait (compose_req);
		raw1 = compose_raw_buf;
		target1 = compose_target_buf;
		if (compose_has_source)
			$fatal(1, "first Blend unexpectedly has a source");
		if (raw1 == target1)
			$fatal(1, "first Blend overwrites raw buffer %0d", raw1);
		present_composite(target1);

		finish_raw_frame();
		wait (compose_req);
		raw2 = compose_raw_buf;
		target2 = compose_target_buf;
		if (!compose_has_source)
			$fatal(1, "second Blend is missing previous raw source");
		if (compose_source_is_composed)
			$fatal(1, "Blend source incorrectly marked accumulated");
		if (compose_source_buf != raw1)
			$fatal(1, "Blend source %0d, expected previous raw %0d",
			       compose_source_buf, raw1);
		if ((raw2 == target2) || (raw2 == compose_source_buf) ||
		    (target2 == compose_source_buf))
			$fatal(1, "raw/source/target are not distinct");
		present_composite(target2);

		if (raw_frame_dropped)
			$fatal(1, "raw frame dropped during nominal two-frame test");
		$display("PASS: provenance-correct Blend ownership");
		$finish;
	end

	initial begin
		#200000;
		$fatal(1, "timeout");
	end
endmodule
