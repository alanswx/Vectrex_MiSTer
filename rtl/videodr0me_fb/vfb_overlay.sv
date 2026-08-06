// ============================================================================
// Palette artwork loader, decoder, and video compositor.
// written 2026 by Videodr0me
//
// Loads VART artwork from MiSTer ROM index 2 into DDRAM, selects the plane
// matching the active resolution, decodes it one row ahead, and blends it
// after final CRT presentation.
// ============================================================================

module vfb_overlay #(
	parameter logic [28:0] ARTWORK_BASE = vfb_layout_pkg::VFB_ARTWORK_BASE,
	parameter logic [28:0] ARTWORK_LAST = vfb_layout_pkg::VFB_ARTWORK_LAST,
	parameter integer MAX_PLANES = 8,
	parameter integer MAX_WIDTH = 2048
) (
	input  logic        clk_sys,
	input  logic        clk_io,
	input  logic        reset,
	input  logic        upload_reset,
	input  logic        arbiter_ready,
	input  logic        video_timing_reset,

	input  logic        processed_path_active,
	input  logic        artwork_enable,
	input  logic  [2:0] artwork_blend,
	input  logic [11:0] render_width,
	input  logic [11:0] render_height,
	output logic        artwork_available,

	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [15:0] ioctl_index,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_data,
	output logic        ioctl_wait,

	input  logic        ce_pix,
	input  logic  [7:0] video_r_in,
	input  logic  [7:0] video_g_in,
	input  logic  [7:0] video_b_in,
	input  logic        video_hs_in,
	input  logic        video_vs_in,
	input  logic        video_hblank_in,
	input  logic        video_vblank_in,
	output logic  [7:0] video_r_out,
	output logic  [7:0] video_g_out,
	output logic  [7:0] video_b_out,
	output logic        video_hs_out,
	output logic        video_vs_out,
	output logic        video_hblank_out,
	output logic        video_vblank_out,

	output logic        upload_write_ready,
	input  logic        upload_write_done,
	output logic [28:0] upload_write_addr,
	output logic  [7:0] upload_write_burstcnt,
	output logic [63:0] upload_write_data,
	output logic  [7:0] upload_write_be,
	input  logic        upload_write_advance,

	output logic        artwork_read_ready,
	input  logic        artwork_read_grant,
	output logic [28:0] artwork_read_addr,
	output logic  [7:0] artwork_read_burstcnt,
	input  logic [63:0] artwork_read_data,
	input  logic        artwork_read_data_valid
);

	localparam integer UPLOAD_EVENT_W = 38;
	localparam integer PALETTE_BYTES = 16384;
	localparam integer PALETTE_WORDS = PALETTE_BYTES / 4;
	localparam integer PALETTE_ADDR_W = $clog2(PALETTE_WORDS);
	localparam integer COMPRESSED_FIFO_DEPTH = 128;
	localparam integer COMPRESSED_FIFO_ADDR_W = $clog2(COMPRESSED_FIFO_DEPTH);
	localparam integer ROW_ADDR_W = $clog2(MAX_WIDTH);
	localparam integer PLANE_INDEX_W = (MAX_PLANES <= 1) ? 1 : $clog2(MAX_PLANES);
	localparam logic [7:0] MAX_PLANES_COUNT = MAX_PLANES[7:0];

	function automatic [31:0] crc32_byte(
		input logic [31:0] crc_in,
		input logic  [7:0] data
	);
		logic [31:0] crc;
		integer bit_index;
		begin
			crc = crc_in ^ {24'd0, data};
			for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
				crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
			crc32_byte = crc;
		end
	endfunction

	function automatic [5:0] descriptor_byte_offset(
		input logic [26:0] address,
		input integer plane_index
	);
		logic [26:0] offset;
		begin
			offset = address - 27'(64 + plane_index * 48);
			descriptor_byte_offset = offset[5:0];
		end
	endfunction

	function automatic logic valid_dimensions(
		input logic [11:0] width,
		input logic [11:0] height
	);
		begin
			valid_dimensions =
				((width == 12'd1360) && (height == 12'd1080)) ||
				((width == 12'd916)  && (height == 12'd720))  ||
				((width == 12'd640)  && (height == 12'd480))  ||
				((width == 12'd640)  && (height == 12'd240));
		end
	endfunction

	function automatic [31:0] expected_pixels(
		input logic [11:0] width,
		input logic [11:0] height
	);
		begin
			case ({width, height})
				{12'd1360, 12'd1080}: expected_pixels = 32'd1468800;
				{12'd916,  12'd720}:  expected_pixels = 32'd659520;
				{12'd640,  12'd480}:  expected_pixels = 32'd307200;
				{12'd640,  12'd240}:  expected_pixels = 32'd153600;
				default:               expected_pixels = 32'd0;
			endcase
		end
	endfunction

	function automatic [10:0] row_word_count(input logic [15:0] encoded_bits);
		logic [16:0] padded_bits;
		begin
			padded_bits = {1'b0, encoded_bits} + 17'd79;
			row_word_count = padded_bits[16:6];
		end
	endfunction

	function automatic [6:0] blend_weight(input logic [2:0] selection);
		begin
			case (selection)
				3'b000: blend_weight = 7'd26; //  0: 40.6%
				3'b001: blend_weight = 7'd27; // +1: 42.2%
				3'b010: blend_weight = 7'd32; // +2: 50.0%
				3'b011: blend_weight = 7'd37; // +3: 57.8%
				3'b100: blend_weight = 7'd20; // -4: 31.3%
				3'b101: blend_weight = 7'd22; // -3: 34.4%
				3'b110: blend_weight = 7'd24; // -2: 37.5%
				default: blend_weight = 7'd25; // -1: 39.1%
			endcase
		end
	endfunction

	// ------------------------------------------------------------------------
	// Upload clock crossing
	// ------------------------------------------------------------------------

	wire upload_active = ioctl_download && (ioctl_index == 16'd2);
	logic upload_active_q = 1'b0;
	logic upload_start_pending = 1'b0;
	logic upload_end_pending = 1'b0;
	logic upload_fifo_wr;
	logic [UPLOAD_EVENT_W-1:0] upload_fifo_wdata;
	wire upload_fifo_full;
	wire upload_fifo_almost_full;
	wire upload_rise = upload_active && !upload_active_q;
	wire upload_fall = !upload_active && upload_active_q;
	logic arbiter_ready_io_meta = 1'b0;
	logic arbiter_ready_io = 1'b0;

	assign ioctl_wait = upload_active &&
	                    (!arbiter_ready_io || upload_fifo_almost_full);

	always_ff @(posedge clk_io) begin
		if (upload_reset) begin
			arbiter_ready_io_meta <= 1'b0;
			arbiter_ready_io <= 1'b0;
		end else begin
			arbiter_ready_io_meta <= arbiter_ready;
			arbiter_ready_io <= arbiter_ready_io_meta;
		end
	end

	always_comb begin
		upload_fifo_wr = 1'b0;
		upload_fifo_wdata = '0;

		if (upload_active && ioctl_wr) begin
			upload_fifo_wr = 1'b1;
			upload_fifo_wdata = {
				upload_start_pending || upload_rise,
				1'b0, 1'b1, ioctl_addr, ioctl_data
			};
		end else if (upload_start_pending || upload_rise) begin
			upload_fifo_wr = 1'b1;
			upload_fifo_wdata = {1'b1, 1'b0, 1'b0, 27'd0, 8'd0};
		end else if (upload_end_pending || upload_fall) begin
			upload_fifo_wr = 1'b1;
			upload_fifo_wdata = {1'b0, 1'b1, 1'b0, 27'd0, 8'd0};
		end
	end

	always_ff @(posedge clk_io) begin
		if (upload_reset) begin
			upload_active_q <= 1'b0;
			upload_start_pending <= 1'b0;
			upload_end_pending <= 1'b0;
		end else begin
			upload_active_q <= upload_active;

			if (upload_rise)
				upload_start_pending <= 1'b1;
			if (upload_fall)
				upload_end_pending <= 1'b1;

			if (upload_fifo_wr && !upload_fifo_full) begin
				if (upload_active && ioctl_wr) begin
					upload_start_pending <= 1'b0;
				end else if (upload_start_pending || upload_rise) begin
					upload_start_pending <= 1'b0;
				end else if (upload_end_pending || upload_fall) begin
					upload_end_pending <= 1'b0;
				end
			end
		end
	end

	logic upload_fifo_rd = 1'b0;
	wire [UPLOAD_EVENT_W-1:0] upload_fifo_rdata;
	wire upload_fifo_rd_valid;
	wire upload_fifo_empty;
	logic [UPLOAD_EVENT_W-1:0] upload_event_q = '0;
	logic upload_event_valid = 1'b0;

	vfb_async_fifo #(
		.WIDTH(UPLOAD_EVENT_W),
		.DEPTH(64),
		.ALMOST_FULL_MARGIN(2)
	) upload_fifo (
		.wr_clk(clk_io),
		.wr_reset(upload_reset),
		.wr_en(upload_fifo_wr),
		.wr_data(upload_fifo_wdata),
		.wr_full(upload_fifo_full),
		.wr_almost_full(upload_fifo_almost_full),
		.rd_clk(clk_sys),
		.rd_reset(upload_reset),
		.rd_en(upload_fifo_rd),
		.rd_data(upload_fifo_rdata),
		.rd_valid(upload_fifo_rd_valid),
		.rd_empty(upload_fifo_empty)
	);

	always_ff @(posedge clk_sys) begin
		if (upload_reset) begin
			upload_event_q <= '0;
			upload_event_valid <= 1'b0;
		end else if (upload_fifo_rd_valid) begin
			upload_event_q <= upload_fifo_rdata;
			upload_event_valid <= 1'b1;
		end else if (upload_event_valid) begin
			upload_event_valid <= 1'b0;
		end
	end

	wire upload_event_start = upload_event_q[37];
	wire upload_event_end = upload_event_q[36];
	wire upload_event_has_data = upload_event_q[35];
	wire [26:0] upload_event_addr = upload_event_q[34:8];
	wire [7:0] upload_event_data = upload_event_q[7:0];

	// ------------------------------------------------------------------------
	// VART upload, metadata, and palette capture
	// ------------------------------------------------------------------------

	logic package_valid = 1'b0;
	logic upload_in_progress = 1'b0;
	logic upload_event_pending = 1'b0;
	logic upload_finalize = 1'b0;
	logic upload_validate = 1'b0;
	logic upload_final_write = 1'b0;
	logic upload_error = 1'b0;
	logic [26:0] upload_expected_addr = 27'd0;
	logic [31:0] upload_received_bytes = 32'd0;
	logic [31:0] upload_crc = 32'hffffffff;
	logic [63:0] upload_pack_data = 64'd0;
	logic  [7:0] upload_pack_be = 8'd0;
	logic        upload_qword_pending = 1'b0;
	logic [28:0] upload_qword_addr = ARTWORK_BASE;
	logic [63:0] upload_qword_data = 64'd0;
	logic  [7:0] upload_qword_be = 8'd0;

	logic [7:0]  vart_layer_count = 8'd0;
	logic [7:0]  vart_plane_count = 8'd0;
	logic [31:0] vart_total_size = 32'd0;
	logic [31:0] vart_expected_crc = 32'd0;
	logic [31:0] vart_descriptor_offset = 32'd0;
	logic [15:0] vart_descriptor_size = 16'd0;

	logic [11:0] plane_width [0:MAX_PLANES-1];
	logic [11:0] plane_height [0:MAX_PLANES-1];
	logic  [7:0] plane_layer [0:MAX_PLANES-1];
	logic  [7:0] plane_role [0:MAX_PLANES-1];
	logic  [7:0] plane_index_bits [0:MAX_PLANES-1];
	logic  [7:0] plane_flags [0:MAX_PLANES-1];
	logic [15:0] plane_palette_entries [0:MAX_PLANES-1];
	logic [31:0] plane_palette_offset [0:MAX_PLANES-1];
	logic [31:0] plane_palette_size [0:MAX_PLANES-1];
	logic [31:0] plane_payload_offset [0:MAX_PLANES-1];
	logic [31:0] plane_payload_size [0:MAX_PLANES-1];
	logic [31:0] plane_pixel_count [0:MAX_PLANES-1];
	logic [31:0] plane_row_count [0:MAX_PLANES-1];
	logic [31:0] plane_layout [0:MAX_PLANES-1];

	(* ramstyle = "M10K, no_rw_check" *)
	logic [31:0] palette_memory [0:PALETTE_WORDS-1];
	logic [PALETTE_ADDR_W-1:0] palette_read_addr = '0;
	logic [31:0] palette_read_data = 32'd0;
	logic [23:0] palette_upload_rgb = 24'd0;

	always_ff @(posedge clk_sys) begin
		if (upload_reset ||
		    (upload_event_valid && upload_event_start)) begin
			palette_upload_rgb <= 24'd0;
		end else if (upload_event_valid && upload_event_has_data &&
		    upload_in_progress && (upload_event_addr[26:14] == 13'd0)) begin
			case (upload_event_addr[1:0])
				2'd0: palette_upload_rgb[7:0] <= upload_event_data;
				2'd1: palette_upload_rgb[15:8] <= upload_event_data;
				2'd2: palette_upload_rgb[23:16] <= upload_event_data;
				default:
					palette_memory[upload_event_addr[13:2]] <=
						{upload_event_data, palette_upload_rgb};
			endcase
		end
		palette_read_data <= palette_memory[palette_read_addr];
	end

	logic metadata_global_valid_q = 1'b0;
	logic [MAX_PLANES-1:0] metadata_plane_valid_q = '0;
	logic [MAX_PLANES-1:0] metadata_plane_required_q = '0;
	logic metadata_valid = 1'b0;
	integer metadata_index;
	always_ff @(posedge clk_sys) begin
		metadata_global_valid_q <= !upload_error &&
		                           (vart_layer_count >= 1) &&
		                           (vart_layer_count <= 2) &&
		                           (vart_plane_count >= 1) &&
		                           (vart_plane_count <= MAX_PLANES_COUNT) &&
		                           (vart_descriptor_offset == 32'd64) &&
		                           (vart_descriptor_size == 16'd48) &&
		                           (vart_total_size >=
		                            (32'd64 + ({24'd0, vart_plane_count} * 32'd48))) &&
		                           (vart_total_size <= 32'd4194304) &&
		                           ((({3'd0, vart_total_size} + 35'd7) >> 3) <=
		                            ({6'd0, ARTWORK_LAST} - {6'd0, ARTWORK_BASE} + 1'b1)) &&
		                           (upload_received_bytes == vart_total_size) &&
		                           ((~upload_crc) == vart_expected_crc);

		for (metadata_index = 0;
		     metadata_index < MAX_PLANES;
		     metadata_index = metadata_index + 1) begin
			metadata_plane_required_q[metadata_index] <=
				(metadata_index < vart_plane_count);
			metadata_plane_valid_q[metadata_index] <=
				valid_dimensions(plane_width[metadata_index],
				                 plane_height[metadata_index]) &&
				(plane_layer[metadata_index] < vart_layer_count) &&
				(plane_role[metadata_index] <= 8'd1) &&
				((plane_index_bits[metadata_index] == 8'd4) ||
				 (plane_index_bits[metadata_index] == 8'd6) ||
				 (plane_index_bits[metadata_index] == 8'd8)) &&
				((plane_flags[metadata_index] & 8'hfc) == 8'd0) &&
				plane_flags[metadata_index][0] &&
				(plane_palette_entries[metadata_index] ==
				 (16'd1 << plane_index_bits[metadata_index])) &&
				(plane_palette_size[metadata_index] ==
				 ({16'd0, plane_palette_entries[metadata_index]} << 2)) &&
				(plane_palette_offset[metadata_index][2:0] == 3'd0) &&
				({1'b0, plane_palette_offset[metadata_index]} +
				 {1'b0, plane_palette_size[metadata_index]} <= 33'd16384) &&
				({1'b0, plane_palette_offset[metadata_index]} +
				 {1'b0, plane_palette_size[metadata_index]} <=
				 {1'b0, vart_total_size}) &&
				(plane_payload_offset[metadata_index][2:0] == 3'd0) &&
				(plane_payload_size[metadata_index][2:0] == 3'd0) &&
				(plane_payload_size[metadata_index] != 32'd0) &&
				({1'b0, plane_payload_offset[metadata_index]} +
				 {1'b0, plane_payload_size[metadata_index]} <=
				 {1'b0, vart_total_size}) &&
				(plane_pixel_count[metadata_index] ==
				 expected_pixels(plane_width[metadata_index],
				                 plane_height[metadata_index])) &&
				(plane_row_count[metadata_index] ==
				 {20'd0, plane_height[metadata_index]}) &&
				(plane_layout[metadata_index] == 32'd0);
		end

		metadata_valid <= metadata_global_valid_q &&
		                  &(metadata_plane_valid_q |
		                    ~metadata_plane_required_q);
	end

	assign upload_write_ready = upload_qword_pending;
	assign upload_write_addr = upload_qword_addr;
	assign upload_write_burstcnt = 8'd1;
	assign upload_write_data = upload_qword_data;
	assign upload_write_be = upload_qword_be;

	integer upload_clear_index;
	integer descriptor_index;
	always_ff @(posedge clk_sys) begin
		upload_fifo_rd <= 1'b0;

		if (upload_reset) begin
			upload_in_progress <= 1'b0;
			upload_event_pending <= 1'b0;
			upload_finalize <= 1'b0;
			upload_validate <= 1'b0;
			upload_final_write <= 1'b0;
			upload_qword_pending <= 1'b0;
			upload_pack_data <= 64'd0;
			upload_pack_be <= 8'd0;
		end else begin
			if (upload_write_advance)
				upload_qword_pending <= 1'b0;

			if (arbiter_ready && !upload_event_pending &&
			    !upload_fifo_empty && !upload_qword_pending &&
			    !upload_finalize && !upload_validate) begin
				upload_fifo_rd <= 1'b1;
				upload_event_pending <= 1'b1;
			end

			if (upload_event_valid) begin
				logic [63:0] next_pack_data;
				logic [7:0] next_pack_be;
				logic [31:0] crc_base;

				upload_event_pending <= 1'b0;

				if (upload_event_start) begin
					package_valid <= 1'b0;
					upload_in_progress <= 1'b1;
					upload_finalize <= 1'b0;
					upload_validate <= 1'b0;
					upload_final_write <= 1'b0;
					upload_error <= 1'b0;
					upload_expected_addr <= 27'd0;
					upload_received_bytes <= 32'd0;
					upload_crc <= 32'hffffffff;
					upload_pack_data <= 64'd0;
					upload_pack_be <= 8'd0;
					vart_layer_count <= 8'd0;
					vart_plane_count <= 8'd0;
					vart_total_size <= 32'd0;
					vart_expected_crc <= 32'd0;
					vart_descriptor_offset <= 32'd0;
					vart_descriptor_size <= 16'd0;
					for (upload_clear_index = 0;
					     upload_clear_index < MAX_PLANES;
					     upload_clear_index = upload_clear_index + 1) begin
						plane_width[upload_clear_index] <= 12'd0;
						plane_height[upload_clear_index] <= 12'd0;
						plane_layer[upload_clear_index] <= 8'd0;
						plane_role[upload_clear_index] <= 8'd0;
						plane_index_bits[upload_clear_index] <= 8'd0;
						plane_flags[upload_clear_index] <= 8'd0;
						plane_palette_entries[upload_clear_index] <= 16'd0;
						plane_palette_offset[upload_clear_index] <= 32'd0;
						plane_palette_size[upload_clear_index] <= 32'd0;
						plane_payload_offset[upload_clear_index] <= 32'd0;
						plane_payload_size[upload_clear_index] <= 32'd0;
						plane_pixel_count[upload_clear_index] <= 32'd0;
						plane_row_count[upload_clear_index] <= 32'd0;
						plane_layout[upload_clear_index] <= 32'd0;
					end
				end

				if (upload_event_has_data &&
				    (upload_in_progress || upload_event_start)) begin
					next_pack_data = upload_event_start ? 64'd0 : upload_pack_data;
					next_pack_be = upload_event_start ? 8'd0 : upload_pack_be;
					crc_base = upload_event_start ? 32'hffffffff : upload_crc;

					if (upload_event_addr !=
					    (upload_event_start ? 27'd0 : upload_expected_addr))
						upload_error <= 1'b1;
					upload_expected_addr <= upload_event_addr + 1'b1;
					upload_received_bytes <=
						(upload_event_start ? 32'd0 : upload_received_bytes) + 1'b1;

					next_pack_data[upload_event_addr[2:0] * 8 +: 8] = upload_event_data;
					next_pack_be[upload_event_addr[2:0]] = 1'b1;
					if (upload_event_addr[2:0] == 3'd7) begin
						upload_qword_pending <= 1'b1;
						upload_qword_addr <= ARTWORK_BASE +
						                     {5'd0, upload_event_addr[26:3]};
						upload_qword_data <= next_pack_data;
						upload_qword_be <= next_pack_be;
						upload_pack_data <= 64'd0;
						upload_pack_be <= 8'd0;
					end else begin
						upload_pack_data <= next_pack_data;
						upload_pack_be <= next_pack_be;
					end

					if (upload_event_addr >= 27'd64)
						upload_crc <= crc32_byte(crc_base, upload_event_data);

					case (upload_event_addr)
						27'd0:  if (upload_event_data != 8'h56) upload_error <= 1'b1;
						27'd1:  if (upload_event_data != 8'h41) upload_error <= 1'b1;
						27'd2:  if (upload_event_data != 8'h52) upload_error <= 1'b1;
						27'd3:  if (upload_event_data != 8'h54) upload_error <= 1'b1;
						27'd4:  if (upload_event_data != 8'd1) upload_error <= 1'b1;
						27'd5:  if (upload_event_data != 8'd0) upload_error <= 1'b1;
						27'd6:  vart_layer_count <= upload_event_data;
						27'd7:  vart_plane_count <= upload_event_data;
						27'd8:  vart_total_size[7:0] <= upload_event_data;
						27'd9:  vart_total_size[15:8] <= upload_event_data;
						27'd10: vart_total_size[23:16] <= upload_event_data;
						27'd11: vart_total_size[31:24] <= upload_event_data;
						27'd12: vart_expected_crc[7:0] <= upload_event_data;
						27'd13: vart_expected_crc[15:8] <= upload_event_data;
						27'd14: vart_expected_crc[23:16] <= upload_event_data;
						27'd15: vart_expected_crc[31:24] <= upload_event_data;
						27'd16: vart_descriptor_offset[7:0] <= upload_event_data;
						27'd17: vart_descriptor_offset[15:8] <= upload_event_data;
						27'd18: vart_descriptor_offset[23:16] <= upload_event_data;
						27'd19: vart_descriptor_offset[31:24] <= upload_event_data;
						27'd20: vart_descriptor_size[7:0] <= upload_event_data;
						27'd21: vart_descriptor_size[15:8] <= upload_event_data;
						default:
							if ((upload_event_addr >= 27'd22) &&
							    (upload_event_addr < 27'd64) &&
							    (upload_event_data != 8'd0))
								upload_error <= 1'b1;
					endcase

					for (descriptor_index = 0;
					     descriptor_index < MAX_PLANES;
					     descriptor_index = descriptor_index + 1) begin
						if ((descriptor_index < vart_plane_count) &&
						    (upload_event_addr >= (27'd64 + descriptor_index * 48)) &&
						    (upload_event_addr <  (27'd112 + descriptor_index * 48))) begin
							case (descriptor_byte_offset(upload_event_addr,
							                             descriptor_index))
								0:  plane_width[descriptor_index][7:0] <= upload_event_data;
								1: begin
									plane_width[descriptor_index][11:8] <= upload_event_data[3:0];
									if (upload_event_data[7:4] != 4'd0) upload_error <= 1'b1;
								end
								2:  plane_height[descriptor_index][7:0] <= upload_event_data;
								3: begin
									plane_height[descriptor_index][11:8] <= upload_event_data[3:0];
									if (upload_event_data[7:4] != 4'd0) upload_error <= 1'b1;
								end
								4:  plane_layer[descriptor_index] <= upload_event_data;
								5:  plane_role[descriptor_index] <= upload_event_data;
								6:  plane_index_bits[descriptor_index] <= upload_event_data;
								7:  plane_flags[descriptor_index] <= upload_event_data;
								8:  plane_palette_entries[descriptor_index][7:0] <= upload_event_data;
								9:  plane_palette_entries[descriptor_index][15:8] <= upload_event_data;
								12: plane_palette_offset[descriptor_index][7:0] <= upload_event_data;
								13: plane_palette_offset[descriptor_index][15:8] <= upload_event_data;
								14: plane_palette_offset[descriptor_index][23:16] <= upload_event_data;
								15: plane_palette_offset[descriptor_index][31:24] <= upload_event_data;
								16: plane_palette_size[descriptor_index][7:0] <= upload_event_data;
								17: plane_palette_size[descriptor_index][15:8] <= upload_event_data;
								18: plane_palette_size[descriptor_index][23:16] <= upload_event_data;
								19: plane_palette_size[descriptor_index][31:24] <= upload_event_data;
								20: plane_payload_offset[descriptor_index][7:0] <= upload_event_data;
								21: plane_payload_offset[descriptor_index][15:8] <= upload_event_data;
								22: plane_payload_offset[descriptor_index][23:16] <= upload_event_data;
								23: plane_payload_offset[descriptor_index][31:24] <= upload_event_data;
								24: plane_payload_size[descriptor_index][7:0] <= upload_event_data;
								25: plane_payload_size[descriptor_index][15:8] <= upload_event_data;
								26: plane_payload_size[descriptor_index][23:16] <= upload_event_data;
								27: plane_payload_size[descriptor_index][31:24] <= upload_event_data;
								28: plane_pixel_count[descriptor_index][7:0] <= upload_event_data;
								29: plane_pixel_count[descriptor_index][15:8] <= upload_event_data;
								30: plane_pixel_count[descriptor_index][23:16] <= upload_event_data;
								31: plane_pixel_count[descriptor_index][31:24] <= upload_event_data;
								32: plane_row_count[descriptor_index][7:0] <= upload_event_data;
								33: plane_row_count[descriptor_index][15:8] <= upload_event_data;
								34: plane_row_count[descriptor_index][23:16] <= upload_event_data;
								35: plane_row_count[descriptor_index][31:24] <= upload_event_data;
								36: plane_layout[descriptor_index][7:0] <= upload_event_data;
								37: plane_layout[descriptor_index][15:8] <= upload_event_data;
								38: plane_layout[descriptor_index][23:16] <= upload_event_data;
								39: plane_layout[descriptor_index][31:24] <= upload_event_data;
								10, 11, 40, 41, 42, 43, 44, 45, 46, 47:
									if (upload_event_data != 8'd0) upload_error <= 1'b1;
								default: ;
							endcase
						end
					end
				end

				if (upload_event_end && upload_in_progress) begin
					upload_finalize <= 1'b1;
					upload_final_write <= (upload_pack_be != 8'd0);
					if (upload_pack_be != 8'd0) begin
						upload_qword_pending <= 1'b1;
						upload_qword_addr <= ARTWORK_BASE +
						                     {5'd0, upload_expected_addr[26:3]};
						upload_qword_data <= upload_pack_data;
						upload_qword_be <= upload_pack_be;
						upload_pack_data <= 64'd0;
						upload_pack_be <= 8'd0;
					end
				end
			end

			if (upload_finalize &&
			    (!upload_final_write || upload_write_done)) begin
				upload_finalize <= 1'b0;
				upload_validate <= 1'b1;
				upload_final_write <= 1'b0;
			end

			if (upload_validate) begin
				package_valid <= metadata_valid;
				upload_in_progress <= 1'b0;
				upload_validate <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------------
	// Plane selection and user controls
	// ------------------------------------------------------------------------

	logic       processed_path_active_q = 1'b0;
	logic       artwork_enable_q = 1'b0;
	logic [2:0] artwork_blend_q = 3'd0;

	always_ff @(posedge clk_sys) begin
		processed_path_active_q <= processed_path_active;
		artwork_enable_q <= artwork_enable;
		artwork_blend_q <= artwork_blend;
	end

	logic [MAX_PLANES-1:0] plane_match_q = '0;
	logic selected_plane_valid_d;
	logic [PLANE_INDEX_W-1:0] selected_plane_index_d;
	logic selected_plane_valid_q = 1'b0;
	logic [PLANE_INDEX_W-1:0] selected_plane_index_q = '0;
	integer match_index;
	integer priority_index;
	logic priority_found;

	// Register each descriptor match before selecting the first one.
	always_ff @(posedge clk_sys) begin
		if (reset || video_timing_reset || !package_valid) begin
			plane_match_q <= '0;
		end else begin
			for (match_index = 0;
			     match_index < MAX_PLANES;
			     match_index = match_index + 1) begin
				plane_match_q[match_index] <=
					(match_index < vart_plane_count) &&
					(plane_role[match_index] == 8'd0) &&
					(plane_width[match_index] == render_width) &&
					(plane_height[match_index] == render_height);
			end
		end
	end

	always_comb begin
		selected_plane_valid_d = 1'b0;
		selected_plane_index_d = '0;
		priority_found = 1'b0;

		for (priority_index = 0;
		     priority_index < MAX_PLANES;
		     priority_index = priority_index + 1) begin
			if (!priority_found && plane_match_q[priority_index]) begin
				selected_plane_valid_d = 1'b1;
				selected_plane_index_d = priority_index[PLANE_INDEX_W-1:0];
				priority_found = 1'b1;
			end
		end
	end

	always_ff @(posedge clk_sys) begin
		if (reset || video_timing_reset || !package_valid) begin
			selected_plane_valid_q <= 1'b0;
			selected_plane_index_q <= '0;
		end else begin
			selected_plane_valid_q <= selected_plane_valid_d;
			selected_plane_index_q <= selected_plane_index_d;
		end
	end

	logic [7:0] selected_index_bits;
	logic [31:0] selected_palette_offset;
	logic [31:0] selected_payload_offset;
	logic [31:0] selected_payload_size;
	always_comb begin
		selected_index_bits = 8'd4;
		selected_palette_offset = 32'd0;
		selected_payload_offset = 32'd0;
		selected_payload_size = 32'd0;

		if (selected_plane_valid_q) begin
			selected_index_bits = plane_index_bits[selected_plane_index_q];
			selected_palette_offset = plane_palette_offset[selected_plane_index_q];
			selected_payload_offset = plane_payload_offset[selected_plane_index_q];
			selected_payload_size = plane_payload_size[selected_plane_index_q];
		end
	end

	typedef enum logic [1:0] {
		INDEX_MODE_4,
		INDEX_MODE_6,
		INDEX_MODE_8
	} index_mode_t;

	logic active_plane_valid = 1'b0;
	index_mode_t active_index_mode = INDEX_MODE_4;
	logic [6:0] active_index_bits = 7'd4;
	logic [31:0] active_palette_offset = 32'd0;
	logic [31:0] active_payload_offset = 32'd0;
	logic [31:0] active_payload_size = 32'd0;

	always_ff @(posedge clk_sys) begin
		if (reset || video_timing_reset) begin
			active_plane_valid <= 1'b0;
			active_index_mode <= INDEX_MODE_4;
			active_index_bits <= 7'd4;
			active_palette_offset <= 32'd0;
			active_payload_offset <= 32'd0;
			active_payload_size <= 32'd0;
		end else begin
			active_plane_valid <= selected_plane_valid_q;
			if (selected_plane_valid_q) begin
				active_palette_offset <= selected_palette_offset;
				active_payload_offset <= selected_payload_offset;
				active_payload_size <= selected_payload_size;
				case (selected_index_bits)
					8'd4: begin
						active_index_mode <= INDEX_MODE_4;
						active_index_bits <= 7'd4;
					end
					8'd6: begin
						active_index_mode <= INDEX_MODE_6;
						active_index_bits <= 7'd6;
					end
					default: begin
						active_index_mode <= INDEX_MODE_8;
						active_index_bits <= 7'd8;
					end
				endcase
			end
		end
	end

	wire active_plane_ready = active_plane_valid && package_valid;
	assign artwork_available = active_plane_ready;
	wire run_requested = active_plane_ready && artwork_enable_q &&
	                     processed_path_active_q;

	// ------------------------------------------------------------------------
	// Lowest-priority sequential DDRAM reader
	// ------------------------------------------------------------------------

	logic compressed_fifo_reset = 1'b1;
	logic compressed_fifo_wr = 1'b0;
	logic [63:0] compressed_fifo_wdata = 64'd0;
	logic compressed_fifo_rd = 1'b0;
	wire [63:0] compressed_fifo_data;
	wire compressed_fifo_full;
	wire compressed_fifo_empty;
	wire [COMPRESSED_FIFO_ADDR_W:0] compressed_fifo_used;

	vfb_sync_fifo #(
		.WIDTH(64),
		.DEPTH(COMPRESSED_FIFO_DEPTH)
	) compressed_fifo (
		.clk_sys(clk_sys),
		.reset(compressed_fifo_reset),
		.wr_en(compressed_fifo_wr),
		.wr_data(compressed_fifo_wdata),
		.full(compressed_fifo_full),
		.rd_en(compressed_fifo_rd),
		.rd_data(compressed_fifo_data),
		.empty(compressed_fifo_empty),
		.used(compressed_fifo_used)
	);

	logic packet_vblank_q = 1'b1;
	logic run_requested_q = 1'b0;
	logic stream_restart_pending = 1'b0;
	logic stream_active = 1'b0;
	logic stream_discard = 1'b1;
	logic stream_decoder_reset = 1'b1;
	logic read_inflight = 1'b0;
	logic [7:0] read_beats_left = 8'd0;
	logic [28:0] stream_fetch_addr = ARTWORK_BASE;
	logic [31:0] stream_words_left = 32'd0;

	wire vblank_rise = ce_pix && video_vblank_in && !packet_vblank_q;
	wire start_during_vblank = run_requested && !run_requested_q &&
	                           video_vblank_in;
	wire restart_now = vblank_rise || start_during_vblank;

	always_ff @(posedge clk_sys) begin
		compressed_fifo_wr <= 1'b0;
		compressed_fifo_reset <= 1'b0;
		stream_decoder_reset <= 1'b0;
		run_requested_q <= run_requested;
		if (ce_pix)
			packet_vblank_q <= video_vblank_in;

		if (reset || video_timing_reset) begin
			artwork_read_ready <= 1'b0;
			read_inflight <= 1'b0;
			read_beats_left <= 8'd0;
			stream_restart_pending <= 1'b0;
			stream_active <= 1'b0;
			stream_discard <= 1'b1;
			compressed_fifo_reset <= 1'b1;
			stream_decoder_reset <= 1'b1;
			compressed_fifo_wdata <= 64'd0;
			packet_vblank_q <= 1'b1;
			run_requested_q <= 1'b0;
		end else begin
			if (!run_requested) begin
				artwork_read_ready <= 1'b0;
				stream_restart_pending <= 1'b0;
				stream_active <= 1'b0;
				stream_discard <= 1'b1;
				compressed_fifo_reset <= 1'b1;
				stream_decoder_reset <= 1'b1;
			end else if (restart_now) begin
				artwork_read_ready <= 1'b0;
				stream_restart_pending <= 1'b1;
				stream_active <= 1'b0;
				stream_discard <= 1'b1;
			end

			if (artwork_read_grant) begin
				artwork_read_ready <= 1'b0;
				read_inflight <= 1'b1;
				read_beats_left <= artwork_read_burstcnt;
				stream_fetch_addr <= stream_fetch_addr +
				                     {21'd0, artwork_read_burstcnt};
				stream_words_left <= stream_words_left -
				                     {24'd0, artwork_read_burstcnt};
			end

			if (artwork_read_data_valid && read_inflight) begin
				if (!stream_discard && !restart_now && !compressed_fifo_full) begin
					compressed_fifo_wr <= 1'b1;
					compressed_fifo_wdata <= artwork_read_data;
				end
				if (read_beats_left == 8'd1) begin
					read_beats_left <= 8'd0;
					read_inflight <= 1'b0;
				end else begin
					read_beats_left <= read_beats_left - 1'b1;
				end
			end

			if (stream_restart_pending && !read_inflight &&
			    !artwork_read_ready) begin
				compressed_fifo_reset <= 1'b1;
				stream_decoder_reset <= 1'b1;
				stream_fetch_addr <= ARTWORK_BASE + active_payload_offset[31:3];
				stream_words_left <= active_payload_size >> 3;
				stream_restart_pending <= 1'b0;
				stream_active <= 1'b1;
				stream_discard <= 1'b0;
			end else if (stream_active && !read_inflight &&
			             !artwork_read_ready && (stream_words_left != 0) &&
			             (compressed_fifo_used <= 8'd64)) begin
				artwork_read_addr <= stream_fetch_addr;
				artwork_read_burstcnt <=
					(stream_words_left >= 32'd32) ? 8'd32 :
					stream_words_left[7:0];
				artwork_read_ready <= 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------------
	// Every encoded artwork command sustains one output pixel per clock.
	// ------------------------------------------------------------------------

	typedef enum logic [3:0] {
		DEC_IDLE,
		DEC_ROW_START,
		DEC_TOKEN,
		DEC_LITERAL,
		DEC_REPEAT,
		DEC_COPY,
		DEC_FINISH,
		DEC_ERROR
	} decode_state_t;

	decode_state_t decode_state = DEC_IDLE;
	// The front stays byte-aligned. The phase selects one of four pair offsets.
	logic [31:0] decode_front = 32'd0;
	logic  [1:0] decode_front_phase = 2'd0;
	logic [79:0] decode_tail = 80'd0;
	logic  [3:0] decode_tail_count = 4'd0;
	logic  [6:0] decode_buffered_pairs = 7'd0;
	logic [14:0] decode_pairs_left = 15'd0;
	logic [10:0] decode_words_remaining = 11'd0;
	logic        decode_word_available = 1'b0;
	logic [11:0] decode_row = 12'd0;
	logic [11:0] decode_x = 12'd0;
	logic [11:0] decode_x_plus_one = 12'd1;
	logic [11:0] decode_room = 12'd0;
	logic  [7:0] decode_run_left = 8'd0;
	logic  [7:0] decode_repeat_value = 8'd0;
	logic        row_write_enable = 1'b0;
	logic        row_write_bank = 1'b0;
	logic [11:0] row_write_addr = 12'd0;
	logic  [7:0] row_write_data = 8'd0;
	logic  [1:0] row_valid = 2'b00;
	logic [11:0] row_number [0:1];
	logic        stream_error = 1'b0;
	logic [63:0] decode_input_word = 64'd0;
	logic        decode_input_valid = 1'b0;

	(* ramstyle = "M10K, no_rw_check" *) logic [7:0] row0_memory [0:MAX_WIDTH-1];
	(* ramstyle = "M10K, no_rw_check" *) logic [7:0] row1_memory [0:MAX_WIDTH-1];
	logic [ROW_ADDR_W-1:0] row0_port_a_addr;
	logic [ROW_ADDR_W-1:0] row1_port_a_addr;
	logic [7:0] row0_copy_data = 8'd0;
	logic [7:0] row1_copy_data = 8'd0;
	logic [7:0] row0_display_data = 8'd0;
	logic [7:0] row1_display_data = 8'd0;
	logic [ROW_ADDR_W-1:0] display_read_addr = '0;

	wire decode_target_bank = decode_row[0];
	wire decode_previous_bank = ~decode_target_bank;
	wire [7:0] decode_previous_data = decode_previous_bank ?
	                                         row1_copy_data : row0_copy_data;

	logic [15:0] decode_window;
	always_comb begin
		case (decode_front_phase)
			2'd0: decode_window = decode_front[15:0];
			2'd1: decode_window = decode_front[17:2];
			2'd2: decode_window = decode_front[19:4];
			default: decode_window = decode_front[21:6];
		endcase
	end

	// All encoded fields contain an even number of bits, so occupancy is tracked in pairs.
	wire [2:0] active_index_pairs = active_index_bits[3:1];
	wire token_is_literal = !decode_window[7];
	wire token_is_repeat = decode_window[7:6] == 2'b10;
	wire token_is_copy = decode_window[7:6] == 2'b11;
	wire [6:0] token_count_minus_one = token_is_literal ?
	                                          decode_window[6:0] :
	                                          {1'b0, decode_window[5:0]};
	wire [3:0] token_required_pairs = token_is_copy ? 4'd4 :
	                                            ({1'b0, active_index_pairs} + 4'd4);
	wire token_fits = {5'd0, token_count_minus_one} < decode_room;
	wire [10:0] row_start_word_count =
		row_word_count(decode_input_word[15:0]);

	wire decoder_stream_state =
		((decode_state == DEC_TOKEN) ||
		 (decode_state == DEC_LITERAL) ||
		 (decode_state == DEC_REPEAT) ||
		 (decode_state == DEC_COPY));
	wire decoder_candidate_consumes =
		(decode_state == DEC_TOKEN) || (decode_state == DEC_LITERAL);
	wire [3:0] decoder_candidate_pairs = !decoder_candidate_consumes ? 4'd0 :
		(decode_state == DEC_TOKEN) ? token_required_pairs :
		{1'b0, active_index_pairs};
	wire [3:0] decoder_phase_sum =
		{2'd0, decode_front_phase} + decoder_candidate_pairs;
	wire [1:0] decoder_candidate_bytes = decoder_phase_sum[3:2];
	wire [1:0] decoder_candidate_phase = decoder_phase_sum[1:0];

	wire decoder_prefetch_tail = decoder_stream_state &&
		(decode_tail_count <= 4'd2) && decode_word_available &&
		decode_input_valid;
	logic [79:0] decode_tail_prefetched;
	logic  [3:0] decode_tail_count_prefetched;
	always_comb begin
		decode_tail_prefetched = decode_tail;
		decode_tail_count_prefetched = decode_tail_count;
		if (decoder_prefetch_tail) begin
			case (decode_tail_count)
				4'd0: decode_tail_prefetched = {16'd0, decode_input_word};
				4'd1: decode_tail_prefetched =
					{8'd0, decode_input_word, decode_tail[7:0]};
				default: decode_tail_prefetched =
					{decode_input_word, decode_tail[15:0]};
			endcase
			decode_tail_count_prefetched = decode_tail_count + 4'd8;
		end
	end

	logic decoder_pairs_available;
	always_comb begin
		decoder_pairs_available = 1'b1;
		case (decode_state)
			DEC_TOKEN: begin
				if (token_is_copy) begin
					decoder_pairs_available = decode_buffered_pairs >= 7'd4;
				end else begin
					case (active_index_mode)
						INDEX_MODE_4:
							decoder_pairs_available = decode_buffered_pairs >= 7'd6;
						INDEX_MODE_6:
							decoder_pairs_available = decode_buffered_pairs >= 7'd7;
						default:
							decoder_pairs_available = decode_buffered_pairs >= 7'd8;
					endcase
				end
			end
			DEC_LITERAL: begin
				case (active_index_mode)
					INDEX_MODE_4:
						decoder_pairs_available = decode_buffered_pairs >= 7'd2;
					INDEX_MODE_6:
						decoder_pairs_available = decode_buffered_pairs >= 7'd3;
					default:
						decoder_pairs_available = decode_buffered_pairs >= 7'd4;
				endcase
			end
			default: begin end
		endcase
	end
	wire decoder_stream_ready = decoder_prefetch_tail ||
	                            decoder_pairs_available;
	logic decoder_emit_without_stream;
	always_comb begin
		decoder_emit_without_stream = 1'b0;
		case (decode_state)
			DEC_TOKEN: begin
				decoder_emit_without_stream =
					(decode_pairs_left >= {11'd0, token_required_pairs}) &&
					(decode_room != 0) && token_fits;
			end
			DEC_LITERAL: begin
				decoder_emit_without_stream =
					(decode_pairs_left >= {12'd0, active_index_pairs}) &&
					(decode_room != 0);
			end
			DEC_REPEAT,
			DEC_COPY: begin
				decoder_emit_without_stream = (decode_room != 0);
			end
			default: begin end
		endcase
	end
	wire decoder_emit = decoder_emit_without_stream && decoder_stream_ready;

	logic decoder_advance_without_stream;
	always_comb begin
		decoder_advance_without_stream = 1'b0;
		case (decode_state)
			DEC_TOKEN: begin
				decoder_advance_without_stream =
					(decode_room != 0) && token_fits;
			end
			DEC_LITERAL: begin
				decoder_advance_without_stream =
					(decode_room != 0) && (decode_run_left != 0);
			end
			DEC_REPEAT,
			DEC_COPY: begin
				decoder_advance_without_stream =
					(decode_room != 0) && (decode_run_left != 0);
			end
			default: begin end
		endcase
	end
	wire decoder_advance_without_refill =
		decoder_advance_without_stream && decoder_pairs_available;
	wire decoder_prefetch_advance = decoder_prefetch_tail ?
		decoder_advance_without_stream : decoder_advance_without_refill;

	wire decoder_consumes_front =
		decoder_emit && decoder_candidate_consumes;
	wire decoder_consumes_front_with_refill =
		decoder_emit_without_stream && decoder_candidate_consumes;
	wire [1:0] decoder_byte_advance = decoder_consumes_front ?
		decoder_candidate_bytes : 2'd0;
	wire [6:0] decode_buffered_pairs_consumed =
		decode_buffered_pairs - {3'd0, decoder_candidate_pairs};
	// A refill occurs with at most two tail bytes, so occupancy is below 32 pairs.
	wire [6:0] decode_buffered_pairs_refilled =
		{1'b0, 1'b1, decode_buffered_pairs[4:0]};
	wire [6:0] decode_buffered_pairs_refilled_consumed =
		decode_buffered_pairs_refilled - {3'd0, decoder_candidate_pairs};

	logic [31:0] decode_front_next;
	logic [79:0] decode_tail_next;
	logic  [3:0] decode_tail_count_next;
	always_comb begin
		case (decoder_byte_advance)
			2'd1: begin
				decode_front_next =
					{decode_tail_prefetched[7:0], decode_front[31:8]};
				decode_tail_next = decode_tail_prefetched >> 8;
			end
			2'd2: begin
				decode_front_next =
					{decode_tail_prefetched[15:0], decode_front[31:16]};
				decode_tail_next = decode_tail_prefetched >> 16;
			end
			default: begin
				decode_front_next = decode_front;
				decode_tail_next = decode_tail_prefetched;
			end
		endcase
		decode_tail_count_next =
			(decode_tail_count_prefetched >= {2'd0, decoder_byte_advance}) ?
			(decode_tail_count_prefetched - {2'd0, decoder_byte_advance}) :
			4'd0;
	end

	logic [11:0] copy_source_addr;
	always_comb begin
		copy_source_addr = ((decode_state == DEC_IDLE) ||
		                    (decode_state == DEC_ROW_START)) ? 12'd0 : decode_x;
		if ((decode_state != DEC_IDLE) &&
		    (decode_state != DEC_ROW_START) && decoder_prefetch_advance)
			copy_source_addr = decode_x_plus_one;
	end

	always_comb begin
		row0_port_a_addr = '0;
		row1_port_a_addr = '0;
		if (row_write_enable && !row_write_bank)
			row0_port_a_addr = row_write_addr[ROW_ADDR_W-1:0];
		else if (decode_previous_bank == 1'b0)
			row0_port_a_addr = copy_source_addr[ROW_ADDR_W-1:0];

		if (row_write_enable && row_write_bank)
			row1_port_a_addr = row_write_addr[ROW_ADDR_W-1:0];
		else if (decode_previous_bank == 1'b1)
			row1_port_a_addr = copy_source_addr[ROW_ADDR_W-1:0];
	end

	always_ff @(posedge clk_sys) begin
		if (row_write_enable && !row_write_bank)
			row0_memory[row0_port_a_addr] <= row_write_data;
		else
			row0_copy_data <= row0_memory[row0_port_a_addr];
		row0_display_data <= row0_memory[display_read_addr];
	end

	always_ff @(posedge clk_sys) begin
		if (row_write_enable && row_write_bank)
			row1_memory[row1_port_a_addr] <= row_write_data;
		else
			row1_copy_data <= row1_memory[row1_port_a_addr];
		row1_display_data <= row1_memory[display_read_addr];
	end

	logic packet_hblank_q = 1'b1;
	logic [11:0] display_line = 12'd0;
	logic display_bank = 1'b0;
	logic frame_artwork_ok = 1'b0;

	wire active_line_start = ce_pix && !video_hblank_in && packet_hblank_q;
	wire active_frame_start = active_line_start && !video_vblank_in &&
	                          packet_vblank_q;
	wire [11:0] line_at_start = active_frame_start ? 12'd0 :
	                            (display_line + 1'b1);
	wire bank_at_start = line_at_start[0];
	wire row_ready_at_start = row_valid[bank_at_start] &&
	                          (row_number[bank_at_start] == line_at_start);

	always_ff @(posedge clk_sys) begin
		compressed_fifo_rd <= 1'b0;
		row_write_enable <= 1'b0;

		if (ce_pix)
			packet_hblank_q <= video_hblank_in;

		if (reset || video_timing_reset || stream_decoder_reset) begin
			decode_state <= DEC_IDLE;
			decode_front <= 32'd0;
			decode_front_phase <= 2'd0;
			decode_tail <= 80'd0;
			decode_tail_count <= 4'd0;
			decode_buffered_pairs <= 7'd0;
			decode_pairs_left <= 15'd0;
			decode_words_remaining <= 11'd0;
			decode_word_available <= 1'b0;
			decode_row <= 12'd0;
			decode_x <= 12'd0;
			decode_x_plus_one <= 12'd1;
			decode_room <= 12'd0;
			decode_run_left <= 8'd0;
			row_valid <= 2'b00;
			row_number[0] <= 12'd0;
			row_number[1] <= 12'd0;
			stream_error <= 1'b0;
			display_line <= 12'd0;
			display_bank <= 1'b0;
			frame_artwork_ok <= 1'b0;
			packet_hblank_q <= 1'b1;
			decode_input_word <= 64'd0;
			decode_input_valid <= 1'b0;
		end else begin
			if (!decode_input_valid && !compressed_fifo_empty) begin
				compressed_fifo_rd <= 1'b1;
				decode_input_word <= compressed_fifo_data;
				decode_input_valid <= 1'b1;
			end

			if (decoder_prefetch_tail) begin
				decode_input_valid <= 1'b0;
				decode_words_remaining <= decode_words_remaining - 1'b1;
				decode_word_available <= (decode_words_remaining != 11'd1);
			end
			if (decoder_consumes_front) begin
				decode_front <= decode_front_next;
				decode_front_phase <= decoder_candidate_phase;
			end
			if (decoder_prefetch_tail ||
			    (decoder_consumes_front && (decoder_byte_advance != 0))) begin
				decode_tail <= decode_tail_next;
				decode_tail_count <= decode_tail_count_next;
			end
			if (decoder_prefetch_tail) begin
				decode_buffered_pairs <= decoder_consumes_front_with_refill ?
					decode_buffered_pairs_refilled_consumed :
					decode_buffered_pairs_refilled;
			end else if (decoder_consumes_front) begin
				decode_buffered_pairs <= decode_buffered_pairs_consumed;
			end
			if (decoder_prefetch_advance)
				decode_x_plus_one <= decode_x_plus_one + 1'b1;

			if (vblank_rise)
				frame_artwork_ok <= 1'b0;

			if (active_line_start && !video_vblank_in) begin
				if (active_frame_start) begin
					display_line <= 12'd0;
					display_bank <= 1'b0;
					frame_artwork_ok <= run_requested && row_ready_at_start;
				end else begin
					row_valid[display_bank] <= 1'b0;
					display_line <= line_at_start;
					display_bank <= bank_at_start;
					if (!row_ready_at_start)
						frame_artwork_ok <= 1'b0;
				end
			end

			case (decode_state)
				DEC_IDLE: begin
					if (stream_active && !stream_error &&
					    (decode_row < render_height) &&
					    !row_valid[decode_target_bank] &&
					    ((decode_row == 0) ||
					     (row_valid[decode_previous_bank] &&
					      (row_number[decode_previous_bank] == decode_row - 1'b1))) &&
					    decode_input_valid)
						decode_state <= DEC_ROW_START;
				end

				DEC_ROW_START: begin
					if (decode_input_valid) begin
						decode_input_valid <= 1'b0;
						if (decode_input_word[0]) begin
							decode_state <= DEC_ERROR;
						end else begin
							decode_pairs_left <= decode_input_word[15:1];
							decode_words_remaining <= row_start_word_count - 1'b1;
							decode_word_available <= (row_start_word_count > 11'd1);
							decode_front <= decode_input_word[47:16];
							decode_front_phase <= 2'd0;
							decode_tail <= {64'd0, decode_input_word[63:48]};
							decode_tail_count <= 4'd2;
							decode_buffered_pairs <= 7'd24;
							decode_x <= 12'd0;
							decode_x_plus_one <= 12'd1;
							decode_room <= render_width;
							decode_run_left <= 8'd0;
							decode_state <= DEC_TOKEN;
						end
					end
				end

				DEC_TOKEN: begin
					if ((decode_room == 0) && (decode_pairs_left == 0)) begin
						decode_state <= DEC_FINISH;
					end else if ((decode_room == 0) || (decode_pairs_left < 4)) begin
						decode_state <= DEC_ERROR;
					end else if (!token_fits) begin
						decode_state <= DEC_ERROR;
					end else if (decode_pairs_left < {11'd0, token_required_pairs}) begin
						decode_state <= DEC_ERROR;
					end else if (!decoder_stream_ready) begin
						if (!decode_word_available)
							decode_state <= DEC_ERROR;
					end else begin
						row_write_enable <= 1'b1;
						row_write_bank <= decode_target_bank;
						row_write_addr <= decode_x;
						decode_x <= decode_x + 1'b1;
						decode_room <= decode_room - 1'b1;
						decode_run_left <= {1'b0, token_count_minus_one};

						if (token_is_literal || token_is_repeat) begin
							case (active_index_mode)
								INDEX_MODE_4: begin
									row_write_data <= {4'd0, decode_window[11:8]};
									decode_repeat_value <= {4'd0, decode_window[11:8]};
									decode_pairs_left <= decode_pairs_left - 15'd6;
								end
								INDEX_MODE_6: begin
									row_write_data <= {2'd0, decode_window[13:8]};
									decode_repeat_value <= {2'd0, decode_window[13:8]};
									decode_pairs_left <= decode_pairs_left - 15'd7;
								end
								default: begin
									row_write_data <= decode_window[15:8];
									decode_repeat_value <= decode_window[15:8];
									decode_pairs_left <= decode_pairs_left - 15'd8;
								end
							endcase
							if (token_count_minus_one == 0)
								decode_state <= DEC_TOKEN;
							else if (token_is_literal)
								decode_state <= DEC_LITERAL;
							else
								decode_state <= DEC_REPEAT;
						end else begin
							row_write_data <= decode_previous_data;
							decode_pairs_left <= decode_pairs_left - 15'd4;
							decode_state <= (token_count_minus_one == 0) ?
							                DEC_TOKEN : DEC_COPY;
						end
					end
				end

				DEC_LITERAL: begin
					if ((decode_room == 0) ||
					    (decode_run_left == 0) ||
					    (decode_pairs_left < {12'd0, active_index_pairs})) begin
						decode_state <= DEC_ERROR;
					end else if (!decoder_stream_ready) begin
						if (!decode_word_available)
							decode_state <= DEC_ERROR;
					end else begin
						row_write_enable <= 1'b1;
						row_write_bank <= decode_target_bank;
						row_write_addr <= decode_x;
						case (active_index_mode)
							INDEX_MODE_4: begin
								row_write_data <= {4'd0, decode_window[3:0]};
								decode_pairs_left <= decode_pairs_left - 15'd2;
							end
							INDEX_MODE_6: begin
								row_write_data <= {2'd0, decode_window[5:0]};
								decode_pairs_left <= decode_pairs_left - 15'd3;
							end
							default: begin
								row_write_data <= decode_window[7:0];
								decode_pairs_left <= decode_pairs_left - 15'd4;
							end
						endcase
						decode_x <= decode_x + 1'b1;
						decode_room <= decode_room - 1'b1;
						decode_run_left <= decode_run_left - 1'b1;
						if (decode_run_left == 8'd1)
							decode_state <= DEC_TOKEN;
					end
				end

				DEC_REPEAT: begin
					if ((decode_room == 0) || (decode_run_left == 0)) begin
						decode_state <= DEC_ERROR;
					end else begin
						row_write_enable <= 1'b1;
						row_write_bank <= decode_target_bank;
						row_write_addr <= decode_x;
						row_write_data <= decode_repeat_value;
						decode_x <= decode_x + 1'b1;
						decode_room <= decode_room - 1'b1;
						decode_run_left <= decode_run_left - 1'b1;
						if (decode_run_left == 8'd1)
							decode_state <= DEC_TOKEN;
					end
				end

				DEC_COPY: begin
					if ((decode_room == 0) || (decode_run_left == 0)) begin
						decode_state <= DEC_ERROR;
					end else begin
						row_write_enable <= 1'b1;
						row_write_bank <= decode_target_bank;
						row_write_addr <= decode_x;
						row_write_data <= decode_previous_data;
						decode_x <= decode_x + 1'b1;
						decode_room <= decode_room - 1'b1;
						decode_run_left <= decode_run_left - 1'b1;
						if (decode_run_left == 8'd1)
							decode_state <= DEC_TOKEN;
					end
				end

				DEC_FINISH: begin
					if (!row_write_enable) begin
						if (decode_words_remaining != 0) begin
							decode_state <= DEC_ERROR;
						end else begin
							row_valid[decode_target_bank] <= 1'b1;
							row_number[decode_target_bank] <= decode_row;
							decode_row <= decode_row + 1'b1;
							decode_state <= DEC_IDLE;
						end
					end
				end

				DEC_ERROR: begin
					stream_error <= 1'b1;
					frame_artwork_ok <= 1'b0;
				end

				default: decode_state <= DEC_ERROR;
			endcase
		end
	end

	// ------------------------------------------------------------------------
	// Palette lookup and alpha-aware screen blend after CRT effects.
	// ------------------------------------------------------------------------

	typedef struct packed {
		logic [7:0] r;
		logic [7:0] g;
		logic [7:0] b;
		logic       hs;
		logic       vs;
		logic       hblank;
		logic       vblank;
		logic       art_valid;
		logic       row_bank;
	} video_packet_t;

	video_packet_t pixel_s0;
	video_packet_t pixel_s1;
	video_packet_t pixel_s2;
	video_packet_t pixel_s3;
	video_packet_t pixel_s4;
	video_packet_t pixel_s5;
	video_packet_t pixel_s6;
	video_packet_t pixel_s7;
	logic [7:0] background_r_s3 = 8'd0;
	logic [7:0] background_g_s3 = 8'd0;
	logic [7:0] background_b_s3 = 8'd0;
	logic [7:0] background_a_s3 = 8'd0;
	logic [7:0] background_r_s4 = 8'd0;
	logic [7:0] background_g_s4 = 8'd0;
	logic [7:0] background_b_s4 = 8'd0;
	logic [14:0] alpha_weight_s4 = 15'd0;
	logic [6:0] effective_weight_s5 = 7'd0;
	logic [7:0] background_r_s5 = 8'd0;
	logic [7:0] background_g_s5 = 8'd0;
	logic [7:0] background_b_s5 = 8'd0;
	logic [14:0] artwork_r_sum_s6 = 15'd0;
	logic [14:0] artwork_g_sum_s6 = 15'd0;
	logic [14:0] artwork_b_sum_s6 = 15'd0;
	logic [15:0] screen_r_product_s7 = 16'd0;
	logic [15:0] screen_g_product_s7 = 16'd0;
	logic [15:0] screen_b_product_s7 = 16'd0;
	logic [11:0] display_x = 12'd0;
	wire [14:0] alpha_weight_rounded = alpha_weight_s4 + 15'd128;
	wire [14:0] alpha_weight_scaled = alpha_weight_rounded +
	                                          (alpha_weight_rounded >> 8);
	wire [16:0] screen_r_rounded_s7 = 17'(screen_r_product_s7) + 17'd128;
	wire [16:0] screen_g_rounded_s7 = 17'(screen_g_product_s7) + 17'd128;
	wire [16:0] screen_b_rounded_s7 = 17'(screen_b_product_s7) + 17'd128;
	wire [16:0] screen_r_scaled_s7 = screen_r_rounded_s7 +
	                                       (screen_r_rounded_s7 >> 8);
	wire [16:0] screen_g_scaled_s7 = screen_g_rounded_s7 +
	                                       (screen_g_rounded_s7 >> 8);
	wire [16:0] screen_b_scaled_s7 = screen_b_rounded_s7 +
	                                       (screen_b_rounded_s7 >> 8);
	wire [7:0] screen_r_foreground_inv_s6 = pixel_s6.r ^ 8'hff;
	wire [7:0] screen_g_foreground_inv_s6 = pixel_s6.g ^ 8'hff;
	wire [7:0] screen_b_foreground_inv_s6 = pixel_s6.b ^ 8'hff;
	wire [7:0] screen_r_artwork_inv_s6 = artwork_r_sum_s6[13:6] ^ 8'hff;
	wire [7:0] screen_g_artwork_inv_s6 = artwork_g_sum_s6[13:6] ^ 8'hff;
	wire [7:0] screen_b_artwork_inv_s6 = artwork_b_sum_s6[13:6] ^ 8'hff;

	wire [11:0] input_line_number = active_line_start ? line_at_start : display_line;
	wire input_row_bank = active_line_start ? bank_at_start : display_bank;
	wire input_line_ready = active_line_start ?
		(active_frame_start ? row_ready_at_start :
		 (frame_artwork_ok && row_ready_at_start)) :
		(frame_artwork_ok && row_valid[display_bank] &&
		 (row_number[display_bank] == display_line));

	always_ff @(posedge clk_sys) begin
		if (reset || video_timing_reset) begin
			display_x <= 12'd0;
			display_read_addr <= '0;
			palette_read_addr <= '0;
			pixel_s0 <= '0;
			pixel_s1 <= '0;
			pixel_s2 <= '0;
			pixel_s3 <= '0;
			pixel_s4 <= '0;
			pixel_s5 <= '0;
			pixel_s6 <= '0;
			pixel_s7 <= '0;
			video_r_out <= 8'd0;
			video_g_out <= 8'd0;
			video_b_out <= 8'd0;
			video_hs_out <= 1'b1;
			video_vs_out <= 1'b1;
			video_hblank_out <= 1'b1;
			video_vblank_out <= 1'b1;
		end else if (ce_pix) begin
			if (video_hblank_in || video_vblank_in) begin
				display_x <= 12'd0;
				display_read_addr <= '0;
			end else begin
				display_read_addr <=
					display_x[ROW_ADDR_W-1:0] + 1'b1;
				display_x <= display_x + 1'b1;
			end

			pixel_s0.r <= video_r_in;
			pixel_s0.g <= video_g_in;
			pixel_s0.b <= video_b_in;
			pixel_s0.hs <= video_hs_in;
			pixel_s0.vs <= video_vs_in;
			pixel_s0.hblank <= video_hblank_in;
			pixel_s0.vblank <= video_vblank_in;
			pixel_s0.art_valid <= run_requested && input_line_ready &&
			                      !video_hblank_in && !video_vblank_in &&
			                      (input_line_number < render_height);
			pixel_s0.row_bank <= input_row_bank;

			pixel_s1 <= pixel_s0;

			pixel_s2 <= pixel_s1;
			palette_read_addr <=
				active_palette_offset[13:2] +
				{4'd0, (pixel_s0.row_bank ? row1_display_data : row0_display_data)};

			pixel_s3 <= pixel_s2;
			background_r_s3 <= palette_read_data[7:0];
			background_g_s3 <= palette_read_data[15:8];
			background_b_s3 <= palette_read_data[23:16];
			background_a_s3 <= palette_read_data[31:24];

			pixel_s4 <= pixel_s3;
			background_r_s4 <= background_r_s3;
			background_g_s4 <= background_g_s3;
			background_b_s4 <= background_b_s3;
			alpha_weight_s4 <= pixel_s3.art_valid ?
			                   (background_a_s3 * blend_weight(artwork_blend_q)) :
			                   15'd0;

			pixel_s5 <= pixel_s4;
			background_r_s5 <= background_r_s4;
			background_g_s5 <= background_g_s4;
			background_b_s5 <= background_b_s4;
			effective_weight_s5 <= alpha_weight_scaled[14:8];

			pixel_s6 <= pixel_s5;
			artwork_r_sum_s6 <=
				(background_r_s5 * effective_weight_s5) + 15'd32;
			artwork_g_sum_s6 <=
				(background_g_s5 * effective_weight_s5) + 15'd32;
			artwork_b_sum_s6 <=
				(background_b_s5 * effective_weight_s5) + 15'd32;

			pixel_s7 <= pixel_s6;
			screen_r_product_s7 <=
				16'(screen_r_foreground_inv_s6) * 16'(screen_r_artwork_inv_s6);
			screen_g_product_s7 <=
				16'(screen_g_foreground_inv_s6) * 16'(screen_g_artwork_inv_s6);
			screen_b_product_s7 <=
				16'(screen_b_foreground_inv_s6) * 16'(screen_b_artwork_inv_s6);

			video_r_out <= pixel_s7.hblank || pixel_s7.vblank ?
			               8'd0 : 8'd255 - screen_r_scaled_s7[15:8];
			video_g_out <= pixel_s7.hblank || pixel_s7.vblank ?
			               8'd0 : 8'd255 - screen_g_scaled_s7[15:8];
			video_b_out <= pixel_s7.hblank || pixel_s7.vblank ?
			               8'd0 : 8'd255 - screen_b_scaled_s7[15:8];
			video_hs_out <= pixel_s7.hs;
			video_vs_out <= pixel_s7.vs;
			video_hblank_out <= pixel_s7.hblank;
			video_vblank_out <= pixel_s7.vblank;
		end
	end

endmodule
