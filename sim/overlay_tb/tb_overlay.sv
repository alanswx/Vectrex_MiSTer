// Focused testbench for vfb_overlay's upload path, driven the way this
// core drives it: clk_io = clk_sys machine clock at 24 MHz, render clock at
// 125 MHz, a real .art container streamed over ioctl with hps_io pacing
// (wr pulses gated by ioctl_wait). The arbiter is a stub that grants every
// upload burst. The questions it answers: does ioctl_wait release, does
// upload_error stay low, does artwork_available come up?
`timescale 1ns/1ps

module tb_overlay;
	logic clk_sys = 0;   // 125 MHz render/framebuffer clock
	logic clk_io  = 0;   // 24 MHz machine clock (hps_io domain)
	always #4 clk_sys = ~clk_sys;      // 125 MHz
	always #20.833 clk_io = ~clk_io;   // 24 MHz

	logic reset = 1;
	logic upload_reset = 1;

	// ioctl
	logic        ioctl_download = 0;
	logic        ioctl_wr = 0;
	logic [15:0] ioctl_index = 0;
	logic [26:0] ioctl_addr = 0;
	logic  [7:0] ioctl_data = 0;
	wire         ioctl_wait;
	wire         artwork_available;

	// arbiter stub
	wire         upload_write_ready;
	logic        upload_write_done = 0;
	wire  [28:0] upload_write_addr;
	wire   [7:0] upload_write_burstcnt;
	wire  [63:0] upload_write_data;
	wire   [7:0] upload_write_be;
	logic        upload_write_advance = 0;

	wire         artwork_read_ready;
	logic        artwork_read_grant = 0;
	wire  [28:0] artwork_read_addr;
	wire   [7:0] artwork_read_burstcnt;
	logic [63:0] artwork_read_data = 0;
	logic        artwork_read_data_valid = 0;

	vfb_overlay dut (
		.clk_sys(clk_sys),
		.clk_io(clk_io),
		.reset(reset),
		.upload_reset(upload_reset),
		.arbiter_ready(1'b1),
		.video_timing_reset(1'b0),
		.processed_path_active(1'b1),
		.artwork_enable(1'b1),
		.artwork_blend(3'd0),
		.render_width(12'd540),
		.render_height(12'd720),
		.artwork_available(artwork_available),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_index(ioctl_index),
		.ioctl_addr(ioctl_addr),
		.ioctl_data(ioctl_data),
		.ioctl_wait(ioctl_wait),
		.ce_pix(1'b0),
		.video_r_in(8'd0), .video_g_in(8'd0), .video_b_in(8'd0),
		.video_hs_in(1'b0), .video_vs_in(1'b0),
		.video_hblank_in(1'b1), .video_vblank_in(1'b1),
		.video_r_out(), .video_g_out(), .video_b_out(),
		.video_hs_out(), .video_vs_out(),
		.video_hblank_out(), .video_vblank_out(),
		.upload_write_ready(upload_write_ready),
		.upload_write_done(upload_write_done),
		.upload_write_addr(upload_write_addr),
		.upload_write_burstcnt(upload_write_burstcnt),
		.upload_write_data(upload_write_data),
		.upload_write_be(upload_write_be),
		.upload_write_advance(upload_write_advance),
		.artwork_read_ready(artwork_read_ready),
		.artwork_read_grant(artwork_read_grant),
		.artwork_read_addr(artwork_read_addr),
		.artwork_read_burstcnt(artwork_read_burstcnt),
		.artwork_read_data(artwork_read_data),
		.artwork_read_data_valid(artwork_read_data_valid)
	);

	// Arbiter stub: grant every upload burst after a short latency.
	logic [8:0] burst_left = 0;
	always_ff @(posedge clk_sys) begin
		upload_write_done <= 0;
		upload_write_advance <= 0;
		if (burst_left == 0 && upload_write_ready) begin
			burst_left <= {1'b0, upload_write_burstcnt};
		end else if (burst_left != 0) begin
			upload_write_advance <= 1;
			burst_left <= burst_left - 1;
			if (burst_left == 1) upload_write_done <= 1;
		end
	end

	byte container [0:4*1024*1024-1];
	integer csize;

	integer wait_cycles = 0;
	integer max_wait = 0;

	initial begin
		integer fd, i, guard;
		fd = $fopen("mine.art", "rb");
		if (fd == 0) begin $display("FAIL: cannot open mine.art"); $finish; end
		csize = $fread(container, fd);
		$fclose(fd);
		$display("container: %0d bytes", csize);

		repeat (50) @(posedge clk_io);
		reset = 0;
		upload_reset = 0;
		repeat (50) @(posedge clk_io);

		// hps_io-style upload: index set, download high, one byte per few
		// clk_io cycles, honouring ioctl_wait before each write.
		ioctl_index = 16'd2;
		ioctl_download = 1;
		@(posedge clk_io);

		for (i = 0; i < csize; i = i + 1) begin
			guard = 0;
			while (ioctl_wait) begin
				@(posedge clk_io);
				wait_cycles = wait_cycles + 1;
				guard = guard + 1;
				if (guard > wait_cycles + 2_000_000) ;
				if (guard == 1_000_000) begin
					$display("FAIL: ioctl_wait stuck high at byte %0d", i);
					$display("  upload_write_ready=%b burst_left=%0d", upload_write_ready, burst_left);
					$finish;
				end
				if (guard > max_wait) max_wait = guard;
			end
			ioctl_addr = i[26:0];
			ioctl_data = container[i];
			ioctl_wr = 1;
			@(posedge clk_io);
			ioctl_wr = 0;
			@(posedge clk_io);
		end
		ioctl_download = 0;
		ioctl_index = 0;
		$display("upload done, max ioctl_wait run: %0d clk_io cycles", max_wait);

		// give the finalize/validate machinery time
		repeat (200000) @(posedge clk_sys);
		$display("upload_error=%b", dut.upload_error);
		$display("received=%0d total=%0d", dut.upload_received_bytes, dut.vart_total_size);
		$display("crc: computed=%08x expected=%08x", ~dut.upload_crc, dut.vart_expected_crc);
		$display("layer_count=%0d plane_count=%0d", dut.vart_layer_count, dut.vart_plane_count);
		$display("desc_offset=%0d desc_size=%0d", dut.vart_descriptor_offset, dut.vart_descriptor_size);
		$display("metadata_global_valid=%b", dut.metadata_global_valid_q);
		$display("plane_match=%b", dut.plane_match_q);
		$display("plane0: %0dx%0d plane1: %0dx%0d", dut.plane_width[0], dut.plane_height[0], dut.plane_width[1], dut.plane_height[1]);
		if (artwork_available)
			$display("PASS: artwork_available is set");
		else
			$display("FAIL: artwork_available never rose");
		$finish;
	end
endmodule
