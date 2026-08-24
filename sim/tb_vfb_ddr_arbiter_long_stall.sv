`timescale 1ns/1ps

// A granted DDR burst must survive an arbitrarily long lack of progress during
// normal operation.  Abandoning it leaves the requester waiting forever for
// data or completion.
module tb_vfb_ddr_arbiter_long_stall;
	logic clk = 0;
	always #4 clk = ~clk;
	logic reset = 1;
	logic ddram_dout_ready = 0;
	logic compose_read_ready = 1;
	wire compose_read_grant;
	wire compose_read_data_valid;
	wire [7:0] ddram_burstcnt;
	wire [28:0] ddram_addr;
	wire ddram_rd, ddram_we;
	wire [63:0] ddram_din;
	wire [7:0] ddram_be;
	wire reset_busy;
	integer grants = 0;
	integer beats = 0;

	vfb_ddr_arbiter dut (
		.clk_sys(clk), .rst_sys(reset),
		.DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(ddram_burstcnt),
		.DDRAM_ADDR(ddram_addr), .DDRAM_RD(ddram_rd), .DDRAM_WE(ddram_we),
		.DDRAM_DIN(ddram_din), .DDRAM_BE(ddram_be),
		.DDRAM_DOUT(64'h1234), .DDRAM_DOUT_READY(ddram_dout_ready),
		.readout_ready(1'b0), .readout_grant(), .readout_addr(29'h0),
		.readout_burstcnt(9'd1), .readout_data(), .readout_data_valid(),
		.fill_ready(1'b0), .fill_grant(), .fill_addr(29'h1000),
		.fill_burstcnt(8'd1), .fill_data(), .fill_data_valid(),
		.flush_ready(1'b0), .flush_grant(), .flush_done(),
		.flush_addr(29'h2000), .flush_burstcnt(8'd1),
		.flush_din(64'd0), .flush_be(8'hff), .flush_advance(),
		.compose_read_ready(compose_read_ready),
		.compose_read_grant(compose_read_grant),
		.compose_read_addr(29'h3000), .compose_read_burstcnt(8'd16),
		.compose_read_data(), .compose_read_data_valid(compose_read_data_valid),
		.compose_write_ready(1'b0), .compose_write_grant(),
		.compose_write_done(), .compose_write_addr(29'h4000),
		.compose_write_burstcnt(8'd1), .compose_write_data(64'd0),
		.compose_write_be(8'hff), .compose_write_advance(),
		.upload_write_ready(1'b0), .upload_write_done(),
		.upload_write_addr(29'h100000), .upload_write_burstcnt(8'd1),
		.upload_write_data(64'd0), .upload_write_be(8'hff),
		.upload_write_advance(),
		.artwork_read_ready(1'b0), .artwork_read_grant(),
		.artwork_read_addr(29'h180000), .artwork_read_burstcnt(8'd1),
		.artwork_read_data(), .artwork_read_data_valid(),
		.reset_busy(reset_busy)
	);

	always_ff @(posedge clk) begin
		if (compose_read_grant) begin
			grants <= grants + 1;
			compose_read_ready <= 0;
		end
		if (compose_read_data_valid)
			beats <= beats + 1;
	end

	initial begin
		repeat (6) @(posedge clk);
		reset <= 0;
		wait (grants == 1);
		repeat (70000) @(posedge clk);
		if (grants != 1)
			$fatal(1, "normal stalled burst was abandoned/regranted (%0d grants)", grants);
		ddram_dout_ready <= 1;
		repeat (16) @(posedge clk);
		ddram_dout_ready <= 0;
		repeat (3) @(posedge clk);
		if (beats != 16)
			$fatal(1, "stalled burst did not resume: %0d beats", beats);
		$display("PASS: normal DDR burst survives long no-progress interval");
		$finish;
	end

	initial begin
		#2000000;
		$fatal(1, "timeout: state=%0d ready=%0b grants=%0d beats=%0d",
		       dut.arb_state, compose_read_ready, grants, beats);
	end
endmodule
