`timescale 1ns/1ps

module tb_vfb_blend_compositor;
	import vfb_layout_pkg::*;
	logic clk = 0;
	always #4 clk = ~clk;
	logic reset = 1;
	logic compose_req = 0;
	wire compose_done;
	wire [14:0] tilemap_addr;
	wire [4:0] tilemap_write_hot;
	wire tilemap_write_din;
	logic [4:0] tilemap_dout;
	wire read_ready;
	logic read_grant = 0;
	wire [28:0] read_addr;
	wire [7:0] read_burstcnt;
	logic [63:0] read_data = 0;
	logic read_data_valid = 0;
	wire write_ready;
	logic write_grant = 0;
	logic write_done = 0;
	wire [28:0] write_addr;
	wire [7:0] write_burstcnt;
	wire [63:0] write_data;
	wire [7:0] write_be;
	logic write_advance = 0;

	localparam logic [2:0] SOURCE = 3'd1;
	localparam logic [2:0] RAW = 3'd2;
	localparam logic [2:0] TARGET = 3'd3;

	vfb_phosphor_compositor dut (
		.clk_sys(clk), .reset(reset),
		.render_width(12'd8), .render_height(12'd8),
		.intra_frame_mode(2'd0), .inter_frame_mode(2'd1),
		.compose_req(compose_req),
		.compose_source_buf(SOURCE), .compose_raw_buf(RAW),
		.compose_target_buf(TARGET), .compose_has_source(1'b1),
		.compose_source_is_composed(1'b0), .compose_done(compose_done),
		.raw_reference_draw_idx(4'd0),
		.raw_age_map(64'hfedcba9876543210), .raw_frame_age(4'd9),
		.raw_metadata_ready(1'b1),
		.tilemap_addr(tilemap_addr),
		.tilemap_write_hot(tilemap_write_hot),
		.tilemap_write_din(tilemap_write_din),
		.tilemap_dout(tilemap_dout),
		.read_ready(read_ready), .read_grant(read_grant),
		.read_addr(read_addr), .read_burstcnt(read_burstcnt),
		.read_data(read_data), .read_data_valid(read_data_valid),
		.write_ready(write_ready), .write_grant(write_grant),
		.write_done(write_done), .write_addr(write_addr),
		.write_burstcnt(write_burstcnt), .write_data(write_data),
		.write_be(write_be), .write_advance(write_advance)
	);

	always_comb begin
		tilemap_dout = 5'd0;
		tilemap_dout[SOURCE] = 1'b1;
		tilemap_dout[RAW] = 1'b1;
	end

	logic reading = 0;
	logic [28:0] active_read_addr;
	integer read_beat = 0;
	always_ff @(posedge clk) begin
		read_grant <= 0;
		read_data_valid <= 0;
		if (!reading && read_ready) begin
			read_grant <= 1;
			reading <= 1;
			active_read_addr <= read_addr;
			read_beat <= 0;
		end else if (reading) begin
			read_data_valid <= 1;
			if (read_beat == 0) begin
				if (active_read_addr == vfb_buffer_base(SOURCE))
					read_data <= {48'd0, 16'he064};
				else if (active_read_addr == vfb_buffer_base(RAW))
					read_data <= {32'd0, 16'he078, 16'he050};
				else
					$fatal(1, "unexpected read address %h", active_read_addr);
			end else begin
				read_data <= 64'd0;
			end
			if (read_beat == 15)
				reading <= 0;
			else
				read_beat <= read_beat + 1;
		end
	end

	logic writing = 0;
	integer write_beat = 0;
	logic [63:0] first_written_word;
	logic target_commit_seen = 0;
	always_ff @(posedge clk) begin
		write_grant <= 0;
		write_advance <= 0;
		write_done <= 0;
		if (tilemap_write_hot == (5'b00001 << TARGET) && tilemap_write_din)
			target_commit_seen <= 1;
		if (!writing && write_ready) begin
			if (write_addr != vfb_buffer_base(TARGET))
				$fatal(1, "write target %h is not separate target", write_addr);
			write_grant <= 1;
			writing <= 1;
			write_beat <= 0;
		end else if (writing) begin
			write_advance <= 1;
			if (write_beat == 0)
				first_written_word <= write_data;
			if (write_beat == 15) begin
				write_done <= 1;
				writing <= 0;
			end else begin
				write_beat <= write_beat + 1;
			end
		end
	end

	initial begin
		repeat (4) @(posedge clk);
		reset <= 0;
		@(posedge clk);
		compose_req <= 1;
		wait (compose_done);
		@(posedge clk);
		compose_req <= 0;
		if (first_written_word[15:0] != 16'hf064)
			$fatal(1, "overlap pixel %h, expected previous-frame max f064",
			       first_written_word[15:0]);
		if (first_written_word[31:16] != 16'hf078)
			$fatal(1, "new pixel %h, expected current-frame f078",
			       first_written_word[31:16]);
		if (!target_commit_seen)
			$fatal(1, "target tilemap commit incorrect");
		$display("PASS: Blend pixels are max(raw N, raw N-1)");
		$finish;
	end

	initial begin
		#200000;
		$fatal(1, "timeout");
	end
endmodule
