// ============================================================================
// Fixed-priority DDRAM burst arbiter.
// written 2026 by Videodr0me
// Priority is readout, flush, fill, composition, artwork upload, then artwork
// readout. The arbiter routes requests and drains in-flight bursts across
// reset.
// ============================================================================

module vfb_ddr_arbiter (
	input  logic        clk_sys,
	input  logic        rst_sys,

	// DDRAM interface
	input  logic        DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	output              DDRAM_RD,
	output              DDRAM_WE,
	output wire [63:0] DDRAM_DIN,
	output wire [7:0]  DDRAM_BE,
	input  logic [63:0] DDRAM_DOUT,
	input  logic        DDRAM_DOUT_READY,

	// Client interfaces

	// 1. Framebuffer readout (highest priority)
	input  logic        readout_ready,
	output logic        readout_grant,
	input  logic [28:0] readout_addr,
	input  logic [8:0]  readout_burstcnt,
	output logic [63:0] readout_data,
	output logic        readout_data_valid,

	// 3. Cache fill
	input  logic        fill_ready,
	output logic        fill_grant,
	input  logic [28:0] fill_addr,
	input  logic [7:0]  fill_burstcnt,
	output logic [63:0] fill_data,
	output logic        fill_data_valid,

	// 2. Cache flush
	input  logic        flush_ready,
	output logic        flush_grant,
	output logic        flush_done,         // Pulse: last beat accepted
	input  logic [28:0] flush_addr,
	input  logic [7:0]  flush_burstcnt,
	input  logic [63:0] flush_din,          // Current beat data from requester
	input  logic [7:0]  flush_be,           // Current beat byte enables
	output wire         flush_advance,      // Beat accepted; present next beat

	// 4. Inter-frame composition
	input  logic        compose_read_ready,
	output logic        compose_read_grant,
	input  logic [28:0] compose_read_addr,
	input  logic [7:0]  compose_read_burstcnt,
	output logic [63:0] compose_read_data,
	output logic        compose_read_data_valid,

	input  logic        compose_write_ready,
	output logic        compose_write_grant,
	output logic        compose_write_done,
	input  logic [28:0] compose_write_addr,
	input  logic [7:0]  compose_write_burstcnt,
	input  logic [63:0] compose_write_data,
	input  logic [7:0]  compose_write_be,
	output wire         compose_write_advance,

	// 5. Artwork upload
	input  logic        upload_write_ready,
	output logic        upload_write_done,
	input  logic [28:0] upload_write_addr,
	input  logic [7:0]  upload_write_burstcnt,
	input  logic [63:0] upload_write_data,
	input  logic [7:0]  upload_write_be,
	output wire         upload_write_advance,

	// 6. Artwork readout (lowest priority)
	input  logic        artwork_read_ready,
	output logic        artwork_read_grant,
	input  logic [28:0] artwork_read_addr,
	input  logic [7:0]  artwork_read_burstcnt,
	output logic [63:0] artwork_read_data,
	output logic        artwork_read_data_valid,

	output wire         reset_busy          // Active during reset or burst drain
);
	import vfb_layout_pkg::*;

	typedef enum logic [2:0] {
		ARB_IDLE,
		ARB_READOUT,
		ARB_FILL,
		ARB_FLUSH,
		ARB_COMPOSE_READ,
		ARB_COMPOSE_WRITE,
		ARB_UPLOAD_WRITE,
		ARB_ARTWORK_READ
	} arb_state_t;

	arb_state_t arb_state = ARB_IDLE;

	localparam logic [6:0] SELECT_READOUT      = 7'b1000000;
	localparam logic [6:0] SELECT_FLUSH        = 7'b0100000;
	localparam logic [6:0] SELECT_FILL         = 7'b0010000;
	localparam logic [6:0] SELECT_COMPOSE_READ = 7'b0001000;
	localparam logic [6:0] SELECT_COMPOSE_WRITE = 7'b0000100;
	localparam logic [6:0] SELECT_UPLOAD_WRITE = 7'b0000010;
	localparam logic [6:0] SELECT_ARTWORK_READ = 7'b0000001;

	(* keep *) logic [6:0] arb_select;
	always_comb begin
		arb_select = '0;
		if (readout_ready)
			arb_select = SELECT_READOUT;
		else if (flush_ready)
			arb_select = SELECT_FLUSH;
		else if (fill_ready)
			arb_select = SELECT_FILL;
		else if (compose_read_ready)
			arb_select = SELECT_COMPOSE_READ;
		else if (compose_write_ready)
			arb_select = SELECT_COMPOSE_WRITE;
		else if (upload_write_ready)
			arb_select = SELECT_UPLOAD_WRITE;
		else if (artwork_read_ready)
			arb_select = SELECT_ARTWORK_READ;
	end

	logic [8:0] burst_counter = 0;
	logic [8:0] burst_target  = 0;    // Latched burstcnt for drain tracking

	// Treat each reset assertion as one request and finish any active burst.
	logic [1:0] rst_sync = 2'b11;
	always_ff @(posedge clk_sys) rst_sync <= {rst_sync[0], rst_sys};
	wire rst_ext = rst_sync[1];
	logic rst_ext_q = 1'b0;
	always_ff @(posedge clk_sys) rst_ext_q <= rst_ext;
	wire reset_start = rst_ext && !rst_ext_q;

	logic reset_pending = 0;
	wire rst_active = reset_start || reset_pending;
	logic reset_busy_q = 1'b1;
	always_ff @(posedge clk_sys) reset_busy_q <= rst_active;

	// Read and write controls before address and reset checks.
	logic internal_rd = 0;
	logic internal_we = 0;

	// Framebuffer and artwork clients have adjacent but disjoint regions.
	wire framebuffer_address = (DDRAM_ADDR >= VFB_FRAMEBUFFER_BASE) &&
	                           (DDRAM_ADDR <= VFB_FRAMEBUFFER_LAST);
	wire artwork_address = (DDRAM_ADDR >= VFB_ARTWORK_BASE) &&
	                       (DDRAM_ADDR <= VFB_ARTWORK_LAST);
	wire artwork_state = (arb_state == ARB_UPLOAD_WRITE) ||
	                     (arb_state == ARB_ARTWORK_READ);
	wire safe_address = artwork_state ? artwork_address : framebuffer_address;
	assign DDRAM_WE = internal_we && safe_address;
	assign DDRAM_RD = internal_rd && safe_address;

	assign DDRAM_DIN =
		(arb_state == ARB_FLUSH && !rst_active) ? flush_din :
		(arb_state == ARB_COMPOSE_WRITE && !rst_active) ? compose_write_data :
		(arb_state == ARB_UPLOAD_WRITE && !rst_active) ? upload_write_data :
		64'd0;
	assign DDRAM_BE =
		(arb_state == ARB_FLUSH && !rst_active) ? flush_be :
		(arb_state == ARB_COMPOSE_WRITE && !rst_active) ? compose_write_be :
		(arb_state == ARB_UPLOAD_WRITE && !rst_active) ? upload_write_be :
		8'h00;

	assign flush_advance = (arb_state == ARB_FLUSH) && !DDRAM_BUSY && !rst_active;
	assign compose_write_advance = (arb_state == ARB_COMPOSE_WRITE) &&
	                               !DDRAM_BUSY && !rst_active;
	assign upload_write_advance = (arb_state == ARB_UPLOAD_WRITE) &&
	                              !DDRAM_BUSY && !rst_active;
	assign reset_busy = reset_busy_q;

	localparam int RESET_DRAIN_WDOG_BITS = 16;

	logic [RESET_DRAIN_WDOG_BITS-1:0] reset_drain_wdog = '0;

	wire arb_read_state =
		(arb_state == ARB_READOUT) || (arb_state == ARB_FILL) ||
		(arb_state == ARB_COMPOSE_READ) ||
		(arb_state == ARB_ARTWORK_READ);

	wire arb_drain_progress =
		arb_read_state ? DDRAM_DOUT_READY :
		((arb_state == ARB_FLUSH) || (arb_state == ARB_COMPOSE_WRITE) ||
		 (arb_state == ARB_UPLOAD_WRITE))
			? !DDRAM_BUSY :
		1'b0;

	wire reset_read_drain_timeout =
		(arb_state != ARB_IDLE) &&
		!arb_drain_progress &&
		(&reset_drain_wdog);

	always_ff @(posedge clk_sys) begin
		// A held game reset must not block MRA uploads after the drain completes.
		if (reset_start) begin
			if (arb_state != ARB_IDLE) reset_pending <= 1;
		end else if (arb_state == ARB_IDLE) begin
			reset_pending <= 0;
		end

		if (arb_state != ARB_IDLE) begin
			if (arb_drain_progress)
				reset_drain_wdog <= '0;
			else
				reset_drain_wdog <= reset_drain_wdog + 1'b1;
		end else begin
			reset_drain_wdog <= '0;
		end

		// Pulses remain low unless set below.
		readout_grant <= 0;
		fill_grant <= 0;
		flush_grant <= 0;
		flush_done <= 0;
		compose_read_grant <= 0;
		compose_write_grant <= 0;
		compose_write_done <= 0;
		upload_write_done <= 0;
		artwork_read_grant <= 0;
		readout_data_valid <= 0;
		fill_data_valid <= 0;
		compose_read_data_valid <= 0;
		artwork_read_data_valid <= 0;

		if (reset_read_drain_timeout) begin
			arb_state          <= ARB_IDLE;
			reset_pending      <= 1'b0;
			internal_rd        <= 1'b0;
			internal_we        <= 1'b0;
			burst_counter      <= '0;
			burst_target       <= '0;
			readout_grant      <= 1'b0;
			fill_grant         <= 1'b0;
			flush_grant        <= 1'b0;
			compose_read_grant <= 1'b0;
			compose_write_grant <= 1'b0;
			artwork_read_grant <= 1'b0;
			readout_data_valid <= 1'b0;
			fill_data_valid    <= 1'b0;
			compose_read_data_valid <= 1'b0;
			artwork_read_data_valid <= 1'b0;
		end else begin
			case (arb_state)
			ARB_IDLE: begin
				burst_counter <= 0;

				if (!rst_active) begin
					case (arb_select)
					SELECT_READOUT: begin
						arb_state <= ARB_READOUT;
						internal_rd <= 1;
						DDRAM_ADDR <= readout_addr;
						DDRAM_BURSTCNT <= readout_burstcnt[7:0]; // 8'h00 encodes 256 beats.
						burst_target <= readout_burstcnt;
						readout_grant <= 1;
					end
					SELECT_FLUSH: begin
						arb_state <= ARB_FLUSH;
						internal_we <= 1;
						DDRAM_ADDR <= flush_addr;
						DDRAM_BURSTCNT <= flush_burstcnt;
						burst_target <= flush_burstcnt;
						flush_grant <= 1;
					end
					SELECT_FILL: begin
						arb_state <= ARB_FILL;
						internal_rd <= 1;
						DDRAM_ADDR <= fill_addr;
						DDRAM_BURSTCNT <= fill_burstcnt;
						burst_target <= fill_burstcnt;
						fill_grant <= 1;
					end
					SELECT_COMPOSE_READ: begin
						arb_state <= ARB_COMPOSE_READ;
						internal_rd <= 1;
						DDRAM_ADDR <= compose_read_addr;
						DDRAM_BURSTCNT <= compose_read_burstcnt;
						burst_target <= {1'b0, compose_read_burstcnt};
						compose_read_grant <= 1;
					end
					SELECT_COMPOSE_WRITE: begin
						arb_state <= ARB_COMPOSE_WRITE;
						internal_we <= 1;
						DDRAM_ADDR <= compose_write_addr;
						DDRAM_BURSTCNT <= compose_write_burstcnt;
						burst_target <= {1'b0, compose_write_burstcnt};
						compose_write_grant <= 1;
					end
					SELECT_UPLOAD_WRITE: begin
						arb_state <= ARB_UPLOAD_WRITE;
						internal_we <= 1;
						DDRAM_ADDR <= upload_write_addr;
						DDRAM_BURSTCNT <= upload_write_burstcnt;
						burst_target <= {1'b0, upload_write_burstcnt};
					end
					SELECT_ARTWORK_READ: begin
						arb_state <= ARB_ARTWORK_READ;
						internal_rd <= 1;
						DDRAM_ADDR <= artwork_read_addr;
						DDRAM_BURSTCNT <= artwork_read_burstcnt;
						burst_target <= {1'b0, artwork_read_burstcnt};
						artwork_read_grant <= 1;
					end
					default: begin end
					endcase
				end
			end

			ARB_READOUT: begin
				if (!DDRAM_BUSY) internal_rd <= 0;

				if (DDRAM_DOUT_READY) begin
					if (!rst_active) begin
						readout_data <= DDRAM_DOUT;
						readout_data_valid <= 1;
					end
					burst_counter <= burst_counter + 1'b1;
					if (burst_counter == burst_target - 1)
						arb_state <= ARB_IDLE;
				end
			end

			ARB_FILL: begin
				if (!DDRAM_BUSY) internal_rd <= 0;

				if (DDRAM_DOUT_READY) begin
					if (!rst_active) begin
						fill_data <= DDRAM_DOUT;
						fill_data_valid <= 1;
					end
					burst_counter <= burst_counter + 1'b1;
					if (burst_counter == burst_target - 1)
						arb_state <= ARB_IDLE;
				end
			end

			ARB_FLUSH: begin
				if (!DDRAM_BUSY) begin
					burst_counter <= burst_counter + 1'b1;

					if (burst_counter == burst_target - 1) begin
						// The final beat was accepted.
						internal_we <= 0;
						if (!rst_active) flush_done <= 1;
						arb_state <= ARB_IDLE;
					end
				end
			end

			ARB_COMPOSE_READ: begin
				if (!DDRAM_BUSY) internal_rd <= 0;

				if (DDRAM_DOUT_READY) begin
					if (!rst_active) begin
						compose_read_data <= DDRAM_DOUT;
						compose_read_data_valid <= 1;
					end
					burst_counter <= burst_counter + 1'b1;
					if (burst_counter == burst_target - 1'b1)
						arb_state <= ARB_IDLE;
				end
			end

			ARB_COMPOSE_WRITE: begin
				if (!DDRAM_BUSY) begin
					burst_counter <= burst_counter + 1'b1;
					if (burst_counter == burst_target - 1'b1) begin
						internal_we <= 0;
						if (!rst_active) compose_write_done <= 1;
						arb_state <= ARB_IDLE;
					end
				end
			end

			ARB_UPLOAD_WRITE: begin
				if (!DDRAM_BUSY) begin
					burst_counter <= burst_counter + 1'b1;
					if (burst_counter == burst_target - 1'b1) begin
						internal_we <= 0;
						if (!rst_active) upload_write_done <= 1;
						arb_state <= ARB_IDLE;
					end
				end
			end

			ARB_ARTWORK_READ: begin
				if (!DDRAM_BUSY) internal_rd <= 0;

				if (DDRAM_DOUT_READY) begin
					if (!rst_active) begin
						artwork_read_data <= DDRAM_DOUT;
						artwork_read_data_valid <= 1;
					end
					burst_counter <= burst_counter + 1'b1;
					if (burst_counter == burst_target - 1'b1)
						arb_state <= ARB_IDLE;
				end
			end

			default: begin
				arb_state          <= ARB_IDLE;
				reset_pending      <= 1'b0;
				internal_rd        <= 1'b0;
				internal_we        <= 1'b0;
				burst_counter      <= '0;
				burst_target       <= '0;
				readout_data_valid <= 1'b0;
				fill_data_valid    <= 1'b0;
				flush_done         <= 1'b0;
				compose_read_data_valid <= 1'b0;
				compose_write_done <= 1'b0;
				upload_write_done <= 1'b0;
				artwork_read_data_valid <= 1'b0;
			end
		endcase
		end
	end

endmodule
