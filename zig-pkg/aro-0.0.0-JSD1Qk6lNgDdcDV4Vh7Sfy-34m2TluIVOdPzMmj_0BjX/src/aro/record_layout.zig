const std = @import("std");
const Attribute = @import("Attribute.zig");
const Compilation = @import("Compilation.zig");
const Node = @import("Tree.zig").Node;
const Parser = @import("Parser.zig");
const Target = @import("Target.zig");
const TypeStore = @import("TypeStore.zig");
const QualType = TypeStore.QualType;
const Type = TypeStore.Type;
const Record = Type.Record;
const Field = Record.Field;
const RecordLayout = Type.Record.Layout;
const FieldLayout = Type.Record.Field.Layout;
const BITS_PER_BYTE = 8;
const OngoingBitfield = struct {
    size_bits: u64,
    unused_size_bits: u64,
};
pub const Error = error{Overflow};
fn alignForward(addr: u64, alignment: u64) !u64 {
    const forward_addr = try std.math.add(u64, addr, alignment - 1);
    return std.mem.alignBackward(u64, forward_addr, alignment);
}
const SysVContext = struct {
    attr_packed: bool,
    max_field_align_bits: ?u64,
    aligned_bits: u32,
    is_union: bool,
    size_bits: u64,
    ongoing_bitfield: ?OngoingBitfield,
    comp: *const Compilation,
    am: *const Attribute.Map,
    fn layoutFields(self: *SysVContext, fields: []Type.Record.Field) !void {
        for (fields) |*field| {
            if (field.qt.isInvalid()) continue;
            const type_layout = computeLayout(field.qt, self.comp);
            if (self.comp.target.isMinGW()) {
                field.layout = try self.layoutMinGWField(field, type_layout);
            } else {
                if (field.bit_width.unpack()) |bit_width| {
                    field.layout = try self.layoutBitField(type_layout, field, bit_width);
                } else {
                    field.layout = try self.layoutRegularField(type_layout, field);
                }
            }
        }
    }
    fn ignoreTypeAlignment(is_attr_packed: bool, bit_width: ?u32, ongoing_bitfield: ?OngoingBitfield, fld_layout: RecordLayout) bool {
        if (is_attr_packed) return true;
        if (bit_width) |width| {
            if (ongoing_bitfield) |ongoing| {
                if (ongoing.size_bits == fld_layout.size_bits) return true;
            } else {
                if (width == 0) return true;
            }
        }
        return false;
    }
    fn layoutMinGWField(
        self: *SysVContext,
        field: *const Field,
        field_layout: RecordLayout,
    ) !FieldLayout {
        const annotation_alignment_bits = BITS_PER_BYTE * (self.am.requestedAlignment(field.field_decl, self.comp) orelse 1);
        const is_attr_packed = self.attr_packed or self.am.hasAttribute(field.field_decl, .@"packed");
        const ignore_type_alignment = ignoreTypeAlignment(is_attr_packed, field.bit_width.unpack(), self.ongoing_bitfield, field_layout);
        var field_alignment_bits: u64 = field_layout.field_alignment_bits;
        if (ignore_type_alignment) {
            field_alignment_bits = BITS_PER_BYTE;
        }
        field_alignment_bits = @max(field_alignment_bits, annotation_alignment_bits);
        if (self.max_field_align_bits) |bits| {
            field_alignment_bits = @min(field_alignment_bits, bits);
        }
        const update_record_alignment =
            field.bit_width == .null or
            (field.bit_width.unpack().? == 0 and self.ongoing_bitfield != null) or
            (field.bit_width.unpack().? != 0 and !is_attr_packed);
        if (update_record_alignment) {
            var ty_alignment_bits = field_layout.field_alignment_bits;
            if (is_attr_packed and (field.bit_width == .null or field.bit_width.unpack().? != 0)) {
                ty_alignment_bits = BITS_PER_BYTE;
            }
            ty_alignment_bits = @max(ty_alignment_bits, annotation_alignment_bits);
            if (self.max_field_align_bits) |bits| {
                ty_alignment_bits = @intCast(@min(ty_alignment_bits, bits));
            }
            self.aligned_bits = @max(self.aligned_bits, ty_alignment_bits);
        }
        if (field.bit_width.unpack()) |bit_width| {
            return self.layoutBitFieldMinGW(field_layout.size_bits, field_alignment_bits, field.name_tok != 0, bit_width);
        } else {
            return self.layoutRegularFieldMinGW(field_layout.size_bits, field_alignment_bits);
        }
    }
    fn layoutBitFieldMinGW(
        self: *SysVContext,
        ty_size_bits: u64,
        field_alignment_bits: u64,
        is_named: bool,
        width: u64,
    ) !FieldLayout {
        std.debug.assert(width <= ty_size_bits); 
        if (self.is_union) {
            self.size_bits = @max(self.size_bits, width);
            if (!is_named) return .{};
            return .{
                .offset_bits = 0,
                .size_bits = width,
            };
        }
        if (width == 0) {
            self.ongoing_bitfield = null;
        } else {
            if (self.ongoing_bitfield) |*ongoing| {
                if (ongoing.size_bits == ty_size_bits and ongoing.unused_size_bits >= width) {
                    const offset_bits = self.size_bits - ongoing.unused_size_bits;
                    ongoing.unused_size_bits -= width;
                    if (!is_named) return .{};
                    return .{
                        .offset_bits = offset_bits,
                        .size_bits = width,
                    };
                }
            }
            self.ongoing_bitfield = .{
                .size_bits = ty_size_bits,
                .unused_size_bits = ty_size_bits - width,
            };
        }
        const offset_bits = try alignForward(self.size_bits, field_alignment_bits);
        self.size_bits = if (width == 0) offset_bits else try std.math.add(u64, offset_bits, ty_size_bits);
        if (!is_named) return .{};
        return .{
            .offset_bits = offset_bits,
            .size_bits = width,
        };
    }
    fn layoutRegularFieldMinGW(
        self: *SysVContext,
        ty_size_bits: u64,
        field_alignment_bits: u64,
    ) !FieldLayout {
        self.ongoing_bitfield = null;
        const offset_bits = if (self.is_union) 0 else try alignForward(self.size_bits, field_alignment_bits);
        self.size_bits = @max(self.size_bits, try std.math.add(u64, offset_bits, ty_size_bits));
        return .{
            .offset_bits = offset_bits,
            .size_bits = ty_size_bits,
        };
    }
    fn layoutRegularField(
        self: *SysVContext,
        fld_layout: RecordLayout,
        field: *const Record.Field,
    ) !FieldLayout {
        var fld_align_bits = fld_layout.field_alignment_bits;
        if (self.attr_packed or self.am.hasAttribute(field.field_decl, .@"packed")) {
            fld_align_bits = BITS_PER_BYTE;
        }
        if (self.am.requestedAlignment(field.field_decl, self.comp)) |anno| {
            fld_align_bits = @max(fld_align_bits, @as(u32, anno) * BITS_PER_BYTE);
        }
        if (self.max_field_align_bits) |req_bits| {
            fld_align_bits = @intCast(@min(fld_align_bits, req_bits));
        }
        const offset_bits = if (self.is_union) 0 else try alignForward(self.size_bits, fld_align_bits);
        const size_bits = fld_layout.size_bits;
        self.size_bits = @max(self.size_bits, try std.math.add(u64, offset_bits, size_bits));
        self.aligned_bits = @max(self.aligned_bits, fld_align_bits);
        return .{
            .offset_bits = offset_bits,
            .size_bits = size_bits,
        };
    }
    fn layoutBitField(
        self: *SysVContext,
        fld_layout: RecordLayout,
        field: *const Record.Field,
        bit_width: u64,
    ) !FieldLayout {
        const is_named = field.name_tok != 0;
        const ty_size_bits = fld_layout.size_bits;
        var ty_fld_algn_bits: u32 = fld_layout.field_alignment_bits;
        const target = &self.comp.target;
        if (bit_width > 0) {
            std.debug.assert(bit_width <= ty_size_bits); 
            if (target.ignoreNonZeroSizedBitfieldTypeAlignment()) {
                ty_fld_algn_bits = 1;
            }
        } else {
            if (target.ignoreZeroSizedBitfieldTypeAlignment()) {
                ty_fld_algn_bits = 1;
            }
            if (target.minZeroWidthBitfieldAlignment()) |target_align| {
                ty_fld_algn_bits = @max(ty_fld_algn_bits, target_align);
            }
        }
        const attr_packed = self.attr_packed or self.am.hasAttribute(field.field_decl, .@"packed");
        const has_packing_annotation = attr_packed or self.max_field_align_bits != null;
        const annotation_alignment = if (self.am.requestedAlignment(field.field_decl, self.comp)) |anno| @as(u32, anno) * BITS_PER_BYTE else 1;
        const first_unused_bit: u64 = if (self.is_union) 0 else self.size_bits;
        var field_align_bits: u64 = 1;
        const emulate = self.comp.langopts.emulate;
        if (bit_width == 0) {
            field_align_bits = @max(ty_fld_algn_bits, annotation_alignment);
        } else if (emulate == .gcc) {
            field_align_bits = annotation_alignment;
            if (self.max_field_align_bits) |max_bits| {
                field_align_bits = @min(annotation_alignment, max_bits);
            }
            if (!has_packing_annotation) {
                const start_bit = try alignForward(first_unused_bit, field_align_bits);
                const does_field_cross_boundary = start_bit % ty_fld_algn_bits + bit_width > ty_size_bits;
                if (ty_fld_algn_bits > ty_size_bits or does_field_cross_boundary) {
                    field_align_bits = @max(field_align_bits, ty_fld_algn_bits);
                }
            }
        } else {
            std.debug.assert(emulate == .no or emulate == .clang);
            if (annotation_alignment <= self.max_field_align_bits orelse std.math.maxInt(u29)) {
                field_align_bits = @max(field_align_bits, annotation_alignment);
            }
            if (!has_packing_annotation) {
                const does_field_cross_boundary = first_unused_bit % ty_fld_algn_bits + bit_width > ty_size_bits;
                if (does_field_cross_boundary)
                    field_align_bits = @max(field_align_bits, ty_fld_algn_bits);
            }
        }
        const offset_bits = try alignForward(first_unused_bit, field_align_bits);
        self.size_bits = @max(self.size_bits, try std.math.add(u64, offset_bits, bit_width));
        if (is_named or target.unnamedFieldAffectsAlignment()) {
            var inherited_align_bits: u32 = undefined;
            if (bit_width == 0) {
                inherited_align_bits = @max(ty_fld_algn_bits, annotation_alignment);
            } else if (self.max_field_align_bits) |max_align_bits| {
                inherited_align_bits = @max(ty_fld_algn_bits, annotation_alignment);
                inherited_align_bits = @intCast(@min(inherited_align_bits, max_align_bits));
            } else if (attr_packed) {
                inherited_align_bits = annotation_alignment;
            } else {
                inherited_align_bits = @max(ty_fld_algn_bits, annotation_alignment);
            }
            self.aligned_bits = @max(self.aligned_bits, inherited_align_bits);
        }
        if (!is_named) return .{};
        return .{
            .size_bits = bit_width,
            .offset_bits = offset_bits,
        };
    }
};
const MsvcContext = struct {
    req_align_bits: u32,
    max_field_align_bits: ?u32,
    pointer_align_bits: u32,
    field_align_bits: u32,
    size_bits: u64,
    ongoing_bitfield: ?OngoingBitfield,
    contains_non_bitfield: bool,
    is_union: bool,
    comp: *const Compilation,
    am: *const Attribute.Map,
    fn init(
        packed_attr: bool,
        requested_align: ?u32,
        is_union: bool,
        comp: *const Compilation,
        am: *const Attribute.Map,
        pragma_pack: ?u8,
    ) MsvcContext {
        var pack_value: ?u32 = null;
        if (packed_attr) {
            pack_value = BITS_PER_BYTE;
        }
        if (pack_value == null) {
            if (pragma_pack) |pack| {
                pack_value = pack * BITS_PER_BYTE;
            }
        }
        pack_value = msvcPragmaPack(comp, pack_value);
        const must_align = @as(u32, (requested_align orelse 1)) * BITS_PER_BYTE;
        return .{
            .req_align_bits = must_align,
            .pointer_align_bits = must_align,
            .field_align_bits = must_align,
            .size_bits = 0,
            .max_field_align_bits = pack_value,
            .ongoing_bitfield = null,
            .contains_non_bitfield = false,
            .is_union = is_union,
            .comp = comp,
            .am = am,
        };
    }
    fn layoutField(self: *MsvcContext, fld: *const Field) !FieldLayout {
        const type_layout = computeLayout(fld.qt, self.comp);
        var req_align = type_layout.required_alignment_bits;
        if (self.am.requestedAlignment(fld.field_decl, self.comp)) |anno| {
            req_align = @max(@as(u32, anno) * BITS_PER_BYTE, req_align);
        }
        if (fld.bit_width == .null) {
            self.req_align_bits = @max(self.req_align_bits, req_align);
        }
        var fld_align_bits = type_layout.field_alignment_bits;
        if (self.max_field_align_bits) |max_align| {
            fld_align_bits = @min(fld_align_bits, max_align);
        }
        if (fld.qt.requestedAlignment(self.comp)) |type_req_align| {
            fld_align_bits = @max(fld_align_bits, type_req_align * 8);
        }
        if (self.am.hasAttribute(fld.field_decl, .@"packed")) {
            fld_align_bits = BITS_PER_BYTE;
        }
        fld_align_bits = @max(fld_align_bits, req_align);
        if (fld.bit_width.unpack()) |bit_width| {
            return self.layoutBitField(type_layout.size_bits, fld_align_bits, bit_width);
        } else {
            return self.layoutRegularField(type_layout.size_bits, fld_align_bits);
        }
    }
    fn layoutBitField(self: *MsvcContext, ty_size_bits: u64, field_align: u32, bit_width: u32) !FieldLayout {
        if (bit_width == 0) {
            if (self.ongoing_bitfield) |_| {
                self.ongoing_bitfield = null;
            } else {
                return .{ .offset_bits = self.size_bits, .size_bits = bit_width };
            }
        } else {
            std.debug.assert(bit_width <= ty_size_bits);
            if (!self.is_union) {
                if (self.ongoing_bitfield) |*p| {
                    if (p.size_bits == ty_size_bits and p.unused_size_bits >= bit_width) {
                        const offset_bits = self.size_bits - p.unused_size_bits;
                        p.unused_size_bits -= bit_width;
                        return .{ .offset_bits = offset_bits, .size_bits = bit_width };
                    }
                }
            }
            self.ongoing_bitfield = .{ .size_bits = ty_size_bits, .unused_size_bits = ty_size_bits - bit_width };
        }
        const offset_bits = if (!self.is_union) bits: {
            const p_align = if (self.max_field_align_bits) |max_fld_align|
                @min(max_fld_align, field_align)
            else
                field_align;
            self.pointer_align_bits = @max(self.pointer_align_bits, p_align);
            self.field_align_bits = @max(self.field_align_bits, field_align);
            const offset_bits = try alignForward(self.size_bits, field_align);
            self.size_bits = if (bit_width == 0) offset_bits else offset_bits + ty_size_bits;
            break :bits offset_bits;
        } else bits: {
            self.size_bits = @max(self.size_bits, ty_size_bits);
            break :bits 0;
        };
        return .{ .offset_bits = offset_bits, .size_bits = bit_width };
    }
    fn layoutRegularField(self: *MsvcContext, size_bits: u64, field_align: u32) !FieldLayout {
        self.contains_non_bitfield = true;
        self.ongoing_bitfield = null;
        self.pointer_align_bits = @max(self.pointer_align_bits, field_align);
        self.field_align_bits = @max(self.field_align_bits, field_align);
        const offset_bits = switch (self.is_union) {
            true => 0,
            false => try alignForward(self.size_bits, field_align),
        };
        self.size_bits = @max(self.size_bits, offset_bits + size_bits);
        return .{ .offset_bits = offset_bits, .size_bits = size_bits };
    }
    fn handleZeroSizedRecord(self: *MsvcContext) void {
        if (self.is_union) {
            if (self.contains_non_bitfield) {
                self.size_bits = self.field_align_bits;
            } else {
                self.size_bits = 4 * BITS_PER_BYTE;
            }
        } else {
            self.size_bits = @max(self.req_align_bits, 4 * BITS_PER_BYTE);
            self.pointer_align_bits = @intCast(@min(self.pointer_align_bits, self.size_bits));
        }
    }
};
pub fn compute(
    fields: []Type.Record.Field,
    opt_decl: Node.OptIndex,
    is_union: bool,
    comp: *const Compilation,
    am: *const Attribute.Map,
    pragma_pack: ?u8,
) Error!Type.Record.Layout {
    const packed_attr = am.hasAttribute(opt_decl, .@"packed");
    const requested_align = am.requestedAlignment(opt_decl, comp);
    const use_sysv_layout = switch (comp.langopts.emulate) {
        .msvc => false,
        .clang, .no => comp.target.abi != .msvc,
        .gcc => true,
    };
    if (use_sysv_layout) {
        var context: SysVContext = .{
            .attr_packed = packed_attr,
            .max_field_align_bits = if (pragma_pack) |pak| @as(u64, pak) * BITS_PER_BYTE else null,
            .aligned_bits = (requested_align orelse 1) * BITS_PER_BYTE,
            .is_union = is_union,
            .size_bits = 0,
            .comp = comp,
            .am = am,
            .ongoing_bitfield = null,
        };
        try context.layoutFields(fields);
        context.size_bits = try alignForward(context.size_bits, context.aligned_bits);
        return .{
            .size_bits = context.size_bits,
            .field_alignment_bits = context.aligned_bits,
            .pointer_alignment_bits = context.aligned_bits,
            .required_alignment_bits = BITS_PER_BYTE,
        };
    } else {
        var context = MsvcContext.init(packed_attr, requested_align, is_union, comp, am, pragma_pack);
        for (fields) |*field| {
            if (field.qt.isInvalid()) continue;
            field.layout = try context.layoutField(field);
        }
        if (context.size_bits == 0) {
            context.handleZeroSizedRecord();
        }
        context.size_bits = try alignForward(context.size_bits, context.pointer_align_bits);
        return .{
            .size_bits = context.size_bits,
            .field_alignment_bits = context.field_align_bits,
            .pointer_alignment_bits = context.pointer_align_bits,
            .required_alignment_bits = context.req_align_bits,
        };
    }
}
fn computeLayout(qt: QualType, comp: *const Compilation) RecordLayout {
    const requested = BITS_PER_BYTE * (if (comp.langopts.emulate == .msvc)
        msvcRequiredAlignment(qt, comp) orelse 0
    else
        qt.requestedAlignment(comp) orelse 0);
    switch (qt.base(comp).type) {
        .@"struct", .@"union" => |record| {
            return .{
                .size_bits = record.layout.?.size_bits,
                .pointer_alignment_bits = @max(requested, record.layout.?.pointer_alignment_bits),
                .field_alignment_bits = @max(requested, record.layout.?.field_alignment_bits),
                .required_alignment_bits = @max(requested, record.layout.?.required_alignment_bits),
            };
        },
        else => {
            const type_align = qt.alignof(comp) * BITS_PER_BYTE;
            return .{
                .size_bits = BITS_PER_BYTE * (qt.sizeofOrNull(comp) orelse 0),
                .pointer_alignment_bits = type_align,
                .field_alignment_bits = type_align,
                .required_alignment_bits = @max(requested, BITS_PER_BYTE),
            };
        },
    }
}
fn msvcRequiredAlignment(qt: QualType, comp: *const Compilation) ?u32 {
    const child = switch (qt.type(comp)) {
        .array => |array| msvcRequiredAlignment(array.elem, comp),
        .typedef => |typedef| msvcRequiredAlignment(typedef.base, comp),
        .typeof => |typeof| msvcRequiredAlignment(typeof.base, comp),
        .@"struct", .@"union" => |record| if (record.layout) |layout|
            layout.required_alignment_bits / BITS_PER_BYTE
        else
            null,
        else => null,
    };
    return if (qt.requestedAlignment(comp)) |own|
        if (child) |child_alignment| @max(own, child_alignment) else own
    else
        child;
}
pub fn msvcPragmaPack(comp: *const Compilation, pack: ?u32) ?u32 {
    return switch (pack orelse 0) {
        8, 16, 32 => pack,
        64 => if (comp.target.cpu.arch == .x86) null else pack,
        128 => if (comp.target.cpu.arch == .thumb) pack else null,
        else => {
            return switch (comp.target.cpu.arch) {
                .thumb, .aarch64 => 64,
                else => null,
            };
        },
    };
}
