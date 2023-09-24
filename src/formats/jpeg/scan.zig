const std = @import("std");

const color = @import("../../color.zig");
const Image = @import("../../Image.zig");
const ImageReadError = Image.ReadError;

const FrameHeader = @import("frame_header.zig");
const Frame = @import("frame.zig");
const HuffmanReader = @import("huffman.zig").Reader;

const MAX_COMPONENTS = @import("utils.zig").MAX_COMPONENTS;
const MAX_BLOCKS = @import("utils.zig").MAX_BLOCKS;
const MCU = @import("utils.zig").MCU;
const ZigzagOffsets = @import("utils.zig").ZigzagOffsets;

const Self = @This();

const JPEG_DEBUG = false;
const JPEG_VERY_DEBUG = false;

pub fn performScan(frame: *const Frame, reader: Image.Stream.Reader, pixels_opt: *?color.PixelStorage) ImageReadError!void {
    const scan_header = try ScanHeader.read(reader);

    var prediction_values = [3]i12{ 0, 0, 0 };
    var huffman_reader = HuffmanReader.init(reader);
    var mcu_storage: [MAX_COMPONENTS][MAX_BLOCKS]MCU = undefined;

    const mcu_count = Self.calculateMCUCountInFrame(&frame.frame_header);
    for (0..mcu_count) |mcu_id| {
        try Self.decodeMCU(frame, scan_header, &mcu_storage, &huffman_reader, &prediction_values);
        try Self.dequantize(frame, &mcu_storage);
        try frame.renderToPixels(&mcu_storage, mcu_id, &pixels_opt.*.?);
    }
}

fn calculateMCUCountInFrame(frame_header: *const FrameHeader) usize {
    // FIXME: This is very naive and probably only works for Baseline DCT.
    // MCU of non-interleaved is just one block.
    const horizontal_block_count = if (1 < frame_header.components.len) frame_header.getMaxHorizontalSamplingFactor() else 1;
    const vertical_block_count = if (1 < frame_header.components.len) frame_header.getMaxVerticalSamplingFactor() else 1;
    const mcu_width = 8 * horizontal_block_count;
    const mcu_height = 8 * vertical_block_count;
    const mcu_count_per_row = (frame_header.samples_per_row + mcu_width - 1) / mcu_width;
    const mcu_count_per_column = (frame_header.row_count + mcu_height - 1) / mcu_height;
    return mcu_count_per_row * mcu_count_per_column;
}

fn dequantize(self: *const Frame, mcu_storage: *[MAX_COMPONENTS][MAX_BLOCKS]MCU) !void {
    for (self.frame_header.components, 0..) |component, component_id| {
        const block_count = self.frame_header.getBlockCount(component_id);
        for (0..block_count) |i| {
            const block = &mcu_storage[component_id][i];

            if (self.quantization_tables[component.quantization_table_id]) |quantization_table| {
                var sample_id: usize = 0;
                while (sample_id < 64) : (sample_id += 1) {
                    block[sample_id] = block[sample_id] * quantization_table.q8[sample_id];
                }
            } else return ImageReadError.InvalidData;
        }
    }
}

fn decodeMCU(frame: *const Frame, scan_header: ScanHeader, mcu_storage: *[MAX_COMPONENTS][MAX_BLOCKS]MCU, reader: *HuffmanReader, prediction_values: *[3]i12) ImageReadError!void {
    for (scan_header.components, 0..) |maybe_component, component_id| {
        _ = component_id;
        if (maybe_component == null)
            break;

        try Self.decodeMCUComponent(frame, maybe_component.?, mcu_storage, reader, prediction_values);
    }
}

fn decodeMCUComponent(frame: *const Frame, component: ScanComponentSpec, mcu_storage: *[MAX_COMPONENTS][MAX_BLOCKS]MCU, reader: *HuffmanReader, prediction_values: *[3]i12) ImageReadError!void {
    // The encoder might reorder components or omit one if it decides that the
    // file size can be reduced that way. Therefore we need to select the correct
    // destination for this component.
    const component_destination = blk: {
        for (frame.frame_header.components, 0..) |frame_component, i| {
            if (frame_component.id == component.component_selector) {
                break :blk i;
            }
        }

        return ImageReadError.InvalidData;
    };

    const block_count = frame.frame_header.getBlockCount(component_destination);
    for (0..block_count) |i| {
        const mcu = &mcu_storage[component_destination][i];

        // Decode the DC coefficient
        if (frame.dc_huffman_tables[component.dc_table_selector] == null) return ImageReadError.InvalidData;

        reader.setHuffmanTable(&frame.dc_huffman_tables[component.dc_table_selector].?);

        const dc_coefficient = try Self.decodeDCCoefficient(reader, &prediction_values[component_destination]);
        mcu[0] = dc_coefficient;

        // Decode the AC coefficients
        if (frame.ac_huffman_tables[component.ac_table_selector] == null)
            return ImageReadError.InvalidData;

        reader.setHuffmanTable(&frame.ac_huffman_tables[component.ac_table_selector].?);

        try Self.decodeACCoefficients(reader, mcu);
    }
}

fn decodeDCCoefficient(reader: *HuffmanReader, prediction: *i12) ImageReadError!i12 {
    const maybe_magnitude = try reader.readCode();
    if (maybe_magnitude > 11) return ImageReadError.InvalidData;
    const magnitude: u4 = @intCast(maybe_magnitude);

    const diff: i12 = @intCast(try reader.readMagnitudeCoded(magnitude));
    const dc_coefficient = diff + prediction.*;
    prediction.* = dc_coefficient;

    return dc_coefficient;
}

fn decodeACCoefficients(reader: *HuffmanReader, mcu: *MCU) ImageReadError!void {
    var ac: usize = 1;
    var did_see_eob = false;
    while (ac < 64) : (ac += 1) {
        if (did_see_eob) {
            mcu[ZigzagOffsets[ac]] = 0;
            continue;
        }

        const zero_run_length_and_magnitude = try reader.readCode();
        // 00 == EOB
        if (zero_run_length_and_magnitude == 0x00) {
            did_see_eob = true;
            mcu[ZigzagOffsets[ac]] = 0;
            continue;
        }

        const zero_run_length = zero_run_length_and_magnitude >> 4;

        const maybe_magnitude = zero_run_length_and_magnitude & 0xF;
        if (maybe_magnitude > 10) return ImageReadError.InvalidData;
        const magnitude: u4 = @intCast(maybe_magnitude);

        const ac_coefficient: i11 = @intCast(try reader.readMagnitudeCoded(magnitude));

        var i: usize = 0;
        while (i < zero_run_length) : (i += 1) {
            mcu[ZigzagOffsets[ac]] = 0;
            ac += 1;
        }

        mcu[ZigzagOffsets[ac]] = ac_coefficient;
    }
}

pub const ScanComponentSpec = struct {
    component_selector: u8,
    dc_table_selector: u4,
    ac_table_selector: u4,

    pub fn read(reader: Image.Stream.Reader) ImageReadError!ScanComponentSpec {
        const component_selector = try reader.readByte();
        const entropy_coding_selectors = try reader.readByte();

        const dc_table_selector: u4 = @intCast(entropy_coding_selectors >> 4);
        const ac_table_selector: u4 = @intCast(entropy_coding_selectors & 0b11);

        if (JPEG_VERY_DEBUG) {
            std.debug.print("    Component spec: selector={}, DC table ID={}, AC table ID={}\n", .{ component_selector, dc_table_selector, ac_table_selector });
        }

        return ScanComponentSpec{
            .component_selector = component_selector,
            .dc_table_selector = dc_table_selector,
            .ac_table_selector = ac_table_selector,
        };
    }
};

pub const Header = struct {
    components: [4]?ScanComponentSpec,

    ///  first DCT coefficient in each block in zig-zag order
    start_of_spectral_selection: u8,

    /// last DCT coefficient in each block in zig-zag order
    /// 63 for sequential DCT, 0 for lossless
    /// TODO(angelo) add check for this.
    end_of_spectral_selection: u8,
    approximation_high: u4,
    approximation_low: u4,


    pub fn read(reader: Image.Stream.Reader) ImageReadError!Header {
        var segment_size = try reader.readIntBig(u16);
        if (JPEG_DEBUG) std.debug.print("StartOfScan: segment size = 0x{X}\n", .{segment_size});

        const component_count = try reader.readByte();
        if (component_count < 1 or component_count > 4) {
            return ImageReadError.InvalidData;
        }

        var components = [_]?ScanComponentSpec{null} ** 4;

        if (JPEG_VERY_DEBUG) std.debug.print("  Components:\n", .{});
        var i: usize = 0;
        while (i < component_count) : (i += 1) {
            components[i] = try ScanComponentSpec.read(reader);
        }

        const start_of_spectral_selection = try reader.readByte();
        const end_of_spectral_selection = try reader.readByte();

        if (start_of_spectral_selection > 63) {
            return ImageReadError.InvalidData;
        }

        if (end_of_spectral_selection < start_of_spectral_selection or end_of_spectral_selection > 63) {
            return ImageReadError.InvalidData;
        }

        // If Ss = 0, then Se = 63.
        if (start_of_spectral_selection == 0 and end_of_spectral_selection != 63) {
            return ImageReadError.InvalidData;
        }

        if (JPEG_VERY_DEBUG) std.debug.print("  Spectral selection: {}-{}\n", .{ start_of_spectral_selection, end_of_spectral_selection });

        const approximation_bits = try reader.readByte();
        const approximation_high: u4 = @intCast(approximation_bits >> 4);
        const approximation_low: u4 = @intCast(approximation_bits & 0b1111);
        if (JPEG_VERY_DEBUG) std.debug.print("  Approximation bit position: high={} low={}\n", .{ approximation_high, approximation_low });

        std.debug.assert(segment_size == 2 * component_count + 1 + 2 + 1 + 2);

        return Header{
            .components = components,
            .start_of_spectral_selection = start_of_spectral_selection,
            .end_of_spectral_selection = end_of_spectral_selection,
            .approximation_high = approximation_high,
            .approximation_low = approximation_low,
        };
    }
};

const ScanHeader = Header;