`timescale 1ns/1ps

module tb_vfb_six_buffer_layout;
	import vfb_layout_pkg::*;
	initial begin
		if (VFB_BUFFER_COUNT != 6)
			$fatal(1, "expected six framebuffer slots");
		if (vfb_buffer_base(3'd5) != 29'h06550000)
			$fatal(1, "sixth framebuffer base is incorrect");
		if (VFB_FRAMEBUFFER_LAST != 29'h0665ffff)
			$fatal(1, "framebuffer range does not include slot six");
		if (VFB_ARTWORK_BASE != 29'h06660000 ||
		    VFB_ARTWORK_BASE <= VFB_FRAMEBUFFER_LAST)
			$fatal(1, "artwork range overlaps the framebuffer range");
		$display("PASS: six-buffer DDR layout is contiguous and disjoint");
		$finish;
	end
endmodule
