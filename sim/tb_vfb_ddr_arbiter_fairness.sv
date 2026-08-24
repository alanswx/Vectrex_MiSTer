`timescale 1ns/1ps

module tb_vfb_ddr_arbiter_fairness;
	logic clk = 0;
	always #4 clk = ~clk;
	logic reset = 1;
	wire [7:0] ddram_burstcnt;
	wire [28:0] ddram_addr;
	wire ddram_rd, ddram_we;
	wire [63:0] ddram_din;
	wire [7:0] ddram_be;
	wire fill_grant, compose_read_grant, compose_write_grant;
	wire [63:0] compose_read_data;
	wire compose_read_data_valid, reset_busy;
	logic compose_read_ready = 1'b1;
	integer compose_cooldown = 0;
	integer fill_grants = 0;
	integer compose_grants = 0;

	vfb_ddr_arbiter dut (
		.clk_sys(clk), .rst_sys(reset),
		.DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(ddram_burstcnt),
		.DDRAM_ADDR(ddram_addr), .DDRAM_RD(ddram_rd), .DDRAM_WE(ddram_we),
		.DDRAM_DIN(ddram_din), .DDRAM_BE(ddram_be),
		.DDRAM_DOUT(64'h1234), .DDRAM_DOUT_READY(1'b1),
		.readout_ready(1'b0), .readout_grant(), .readout_addr(29'h0),
		.readout_burstcnt(9'd1), .readout_data(), .readout_data_valid(),
		.fill_ready(1'b1), .fill_grant(fill_grant),
		.fill_addr(29'h1000), .fill_burstcnt(8'd1),
		.fill_data(), .fill_data_valid(),
		.flush_ready(1'b0), .flush_grant(), .flush_done(),
		.flush_addr(29'h2000), .flush_burstcnt(8'd1),
		.flush_din(64'd0), .flush_be(8'hff), .flush_advance(),
		.compose_read_ready(compose_read_ready),
		.compose_read_grant(compose_read_grant),
		.compose_read_addr(29'h3000), .compose_read_burstcnt(8'd1),
		.compose_read_data(compose_read_data),
		.compose_read_data_valid(compose_read_data_valid),
		.compose_write_ready(1'b0),
		.compose_write_grant(compose_write_grant),
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
		if (fill_grant) fill_grants <= fill_grants + 1;
		if (compose_read_grant) compose_grants <= compose_grants + 1;
		if (compose_read_grant) begin
			compose_read_ready <= 1'b0;
			compose_cooldown <= 50;
		end else if (!compose_read_ready && compose_cooldown == 0) begin
			compose_read_ready <= 1'b1;
		end else if (!compose_read_ready) begin
			compose_cooldown <= compose_cooldown - 1;
		end
	end

	initial begin
		repeat (6) @(posedge clk);
		reset <= 0;
		repeat (5000) @(posedge clk);
		if (fill_grants < 100)
			$fatal(1, "cache fill made insufficient progress: %0d", fill_grants);
		if (compose_grants < 2)
			$fatal(1, "composition starved behind cache fill: %0d", compose_grants);
		$display("PASS: DDR composition fairness (%0d fill, %0d compose grants)",
		         fill_grants, compose_grants);
		$finish;
	end
endmodule
