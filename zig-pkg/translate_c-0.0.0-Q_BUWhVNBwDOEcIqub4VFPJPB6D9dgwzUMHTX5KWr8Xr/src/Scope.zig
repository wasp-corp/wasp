const std = @import("std");
const aro = @import("aro");
const ast = @import("ast.zig");
const Translator = @import("Translator.zig");
const Scope = @This();
pub const SymbolTable = std.StringArrayHashMapUnmanaged(ast.Node);
pub const AliasList = std.ArrayList(struct {
    alias: []const u8,
    name: []const u8,
});
pub const ContainerMemberFns = struct {
    container_decl_ptr: *ast.Node,
    member_fns: std.ArrayList(*ast.Payload.Func) = .empty,
};
pub const ContainerMemberFnsHashMap = std.ArrayHashMapUnmanaged(
    aro.QualType,
    ContainerMemberFns,
    struct {
        pub fn hash(self: @This(), key: aro.QualType) u32 {
            const auto_hash = std.array_hash_map.getAutoHashFn(aro.QualType, @This());
            return auto_hash(self, key.unqualified());
        }
        pub fn eql(self: @This(), a: aro.QualType, b: aro.QualType, b_index: usize) bool {
            const auto_eql = std.array_hash_map.getAutoEqlFn(aro.QualType, @This());
            return auto_eql(self, a.unqualified(), b.unqualified(), b_index);
        }
    },
    false,
);
id: Id,
parent: ?*Scope,
pub const Id = enum {
    block,
    root,
    condition,
    loop,
    do_loop,
    @"switch",
};
pub const Condition = struct {
    base: Scope,
    block: ?Block = null,
    fn getBlockScope(cond: *Condition, t: *Translator) !*Block {
        if (cond.block) |*b| return b;
        cond.block = try Block.init(t, &cond.base, true);
        return &cond.block.?;
    }
    pub fn deinit(cond: *Condition) void {
        if (cond.block) |*b| b.deinit();
    }
};
pub const Block = struct {
    base: Scope,
    translator: *Translator,
    statements: std.ArrayList(ast.Node),
    variables: AliasList,
    mangle_count: u32 = 0,
    label: ?[]const u8 = null,
    variable_discards: std.StringArrayHashMapUnmanaged(*ast.Payload.Discard),
    return_type: ?aro.QualType = null,
    pub const static_local_prefix = "static_local";
    pub const extern_local_prefix = "extern_local";
    pub fn init(t: *Translator, parent: *Scope, labeled: bool) !Block {
        var blk: Block = .{
            .base = .{
                .id = .block,
                .parent = parent,
            },
            .translator = t,
            .statements = .empty,
            .variables = .empty,
            .variable_discards = .empty,
        };
        if (labeled) {
            blk.label = try blk.makeMangledName("blk");
        }
        return blk;
    }
    pub fn deinit(block: *Block) void {
        block.statements.deinit(block.translator.gpa);
        block.variables.deinit(block.translator.gpa);
        block.variable_discards.deinit(block.translator.gpa);
        block.* = undefined;
    }
    pub fn complete(block: *Block) !ast.Node {
        const arena = block.translator.arena;
        if (block.base.parent.?.id == .do_loop) {
            const alloc_len = block.statements.items.len + @intFromBool(block.base.parent.?.id == .do_loop);
            var stmts = try arena.alloc(ast.Node, alloc_len);
            stmts.len = block.statements.items.len;
            @memcpy(stmts[0..block.statements.items.len], block.statements.items);
            return ast.Node.Tag.block.create(arena, .{
                .label = block.label,
                .stmts = stmts,
            });
        }
        if (block.statements.items.len == 0) return ast.Node.Tag.empty_block.init();
        return ast.Node.Tag.block.create(arena, .{
            .label = block.label,
            .stmts = try arena.dupe(ast.Node, block.statements.items),
        });
    }
    pub fn reserveMangledName(block: *Block, name: []const u8) ![]const u8 {
        return block.createMangledName(name, true, null);
    }
    pub fn makeMangledName(block: *Block, name: []const u8) ![]const u8 {
        return block.createMangledName(name, false, null);
    }
    pub fn createMangledName(block: *Block, name: []const u8, reservation: bool, prefix_opt: ?[]const u8) ![]const u8 {
        const arena = block.translator.arena;
        const name_copy = try arena.dupe(u8, name);
        const alias_base = if (prefix_opt) |prefix|
            try std.fmt.allocPrint(arena, "{s}_{s}", .{ prefix, name })
        else
            name;
        var proposed_name = alias_base;
        while (block.contains(proposed_name)) {
            block.mangle_count += 1;
            proposed_name = try std.fmt.allocPrint(arena, "{s}_{d}", .{ alias_base, block.mangle_count });
        }
        const new_mangle = try block.variables.addOne(block.translator.gpa);
        if (reservation) {
            new_mangle.* = .{ .name = name_copy, .alias = name_copy };
        } else {
            new_mangle.* = .{ .name = name_copy, .alias = proposed_name };
        }
        return proposed_name;
    }
    fn getAlias(block: *Block, name: []const u8) ?[]const u8 {
        for (block.variables.items) |p| {
            if (std.mem.eql(u8, p.name, name))
                return p.alias;
        }
        return block.base.parent.?.getAlias(name);
    }
    fn localContains(block: *Block, name: []const u8) bool {
        for (block.variables.items) |p| {
            if (std.mem.eql(u8, p.alias, name))
                return true;
        }
        return false;
    }
    fn contains(block: *Block, name: []const u8) bool {
        if (block.localContains(name))
            return true;
        return block.base.parent.?.contains(name);
    }
    pub fn discardVariable(block: *Block, name: []const u8) Translator.Error!void {
        const gpa = block.translator.gpa;
        const arena = block.translator.arena;
        const name_node = try ast.Node.Tag.identifier.create(arena, name);
        const discard = try ast.Node.Tag.discard.create(arena, .{ .should_skip = false, .value = name_node });
        try block.statements.append(gpa, discard);
        try block.variable_discards.putNoClobber(gpa, name, discard.castTag(.discard).?);
    }
};
pub const Root = struct {
    base: Scope,
    translator: *Translator,
    sym_table: SymbolTable,
    blank_macros: std.StringArrayHashMapUnmanaged(void),
    nodes: std.ArrayList(ast.Node),
    container_member_fns_map: ContainerMemberFnsHashMap,
    pub fn init(t: *Translator) Root {
        return .{
            .base = .{
                .id = .root,
                .parent = null,
            },
            .translator = t,
            .sym_table = .empty,
            .blank_macros = .empty,
            .nodes = .empty,
            .container_member_fns_map = .empty,
        };
    }
    pub fn deinit(root: *Root) void {
        root.sym_table.deinit(root.translator.gpa);
        root.blank_macros.deinit(root.translator.gpa);
        root.nodes.deinit(root.translator.gpa);
        for (root.container_member_fns_map.values()) |*members| {
            members.member_fns.deinit(root.translator.gpa);
        }
        root.container_member_fns_map.deinit(root.translator.gpa);
    }
    pub fn containsNow(root: *Root, name: []const u8) bool {
        return root.sym_table.contains(name);
    }
    pub fn contains(root: *Root, name: []const u8) bool {
        return root.containsNow(name) or root.translator.global_names.contains(name) or root.translator.weak_global_names.contains(name);
    }
    pub fn addMemberFunction(root: *Root, func_ty: aro.Type.Func, func: *ast.Payload.Func) !void {
        std.debug.assert(func.data.name != null);
        if (func_ty.params.len == 0) return;
        const param1_base = func_ty.params[0].qt.base(root.translator.comp);
        const container_qt = if (param1_base.type == .pointer)
            param1_base.type.pointer.child.base(root.translator.comp).qt
        else
            param1_base.qt;
        if (root.container_member_fns_map.getPtr(container_qt)) |members| {
            try members.member_fns.append(root.translator.gpa, func);
        }
    }
    pub fn processContainerMemberFns(root: *Root) !void {
        const gpa = root.translator.gpa;
        const arena = root.translator.arena;
        var member_names: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer member_names.deinit(gpa);
        for (root.container_member_fns_map.keys(), root.container_member_fns_map.values()) |container_qt, members| {
            const container_name = root.translator.unnamed_typedefs.get(container_qt) orelse
                container_qt.getRecord(root.translator.comp).?.name.lookup(root.translator.comp);
            std.debug.assert(container_name.len > 0);
            member_names.clearRetainingCapacity();
            const decls_ptr = switch (members.container_decl_ptr.tag()) {
                .@"struct", .@"union" => blk_record: {
                    const payload: *ast.Payload.Container = @alignCast(@fieldParentPtr("base", members.container_decl_ptr.ptr_otherwise));
                    for (payload.data.fields) |field| {
                        try member_names.put(gpa, field.name, {});
                    }
                    break :blk_record &payload.data.decls;
                },
                .opaque_literal => blk_opaque: {
                    const container_decl = try ast.Node.Tag.@"opaque".create(arena, .{
                        .layout = .none,
                        .fields = &.{},
                        .decls = &.{},
                    });
                    members.container_decl_ptr.* = container_decl;
                    break :blk_opaque &container_decl.castTag(.@"opaque").?.data.decls;
                },
                else => continue,
            };
            const old_decls = decls_ptr.*;
            const new_decls = try arena.alloc(ast.Node, old_decls.len + members.member_fns.items.len * 2);
            @memcpy(new_decls[0..old_decls.len], old_decls);
            const func_ref_vars = new_decls[old_decls.len..];
            var count: u32 = 0;
            for (members.member_fns.items) |func| {
                const func_name = func.data.name.?;
                const member_name_slot = try member_names.getOrPutValue(gpa, func_name, {});
                if (member_name_slot.found_existing) continue;
                func_ref_vars[count] = try ast.Node.Tag.pub_var_simple.create(arena, .{
                    .name = func_name,
                    .init = try ast.Node.Tag.root_ref.create(arena, func_name),
                });
                count += 1;
            }
            for (members.member_fns.items) |func| {
                const func_name = func.data.name.?;
                const func_name_alias = blk: {
                    const container_name_trimmed = std.mem.trimStart(u8, container_name, "_");
                    const suffix = std.mem.cutPrefix(u8, func_name, container_name_trimmed);
                    if (suffix) |alias| if (alias.len > 0 and alias[0] == '_') {
                        const alias_trimmed = std.mem.trimStart(u8, alias, "_");
                        if (alias_trimmed.len > 0) break :blk alias_trimmed;
                    };
                    const func_name_trimmed = std.mem.trimEnd(u8, func_name, "_");
                    const last_idx = std.mem.findLast(u8, func_name_trimmed, "_") orelse continue;
                    break :blk func_name[last_idx + 1 ..];
                };
                if (root.contains(func_name_alias)) continue;
                const member_name_slot = try member_names.getOrPutValue(gpa, func_name_alias, {});
                if (member_name_slot.found_existing) continue;
                func_ref_vars[count] = try ast.Node.Tag.pub_var_simple.create(arena, .{
                    .name = func_name_alias,
                    .init = try ast.Node.Tag.root_ref.create(arena, func_name),
                });
                count += 1;
            }
            decls_ptr.* = new_decls[0 .. old_decls.len + count];
        }
    }
};
pub const Switch = struct {
    base: Scope,
    label: []const u8,
    label_used: bool = false,
};
pub fn findBlockScope(inner: *Scope, t: *Translator) !*Block {
    var scope = inner;
    while (true) {
        switch (scope.id) {
            .root => unreachable,
            .block => return @fieldParentPtr("base", scope),
            .condition => return @as(*Condition, @fieldParentPtr("base", scope)).getBlockScope(t),
            else => scope = scope.parent.?,
        }
    }
}
pub fn findBlockReturnType(inner: *Scope) aro.QualType {
    var scope = inner;
    while (true) {
        switch (scope.id) {
            .root => unreachable,
            .block => {
                const block: *Block = @fieldParentPtr("base", scope);
                if (block.return_type) |qt| return qt;
                scope = scope.parent.?;
            },
            else => scope = scope.parent.?,
        }
    }
}
pub fn getAlias(scope: *Scope, name: []const u8) ?[]const u8 {
    return switch (scope.id) {
        .root => null,
        .block => @as(*Block, @fieldParentPtr("base", scope)).getAlias(name),
        .loop, .do_loop, .condition, .@"switch" => scope.parent.?.getAlias(name),
    };
}
fn contains(scope: *Scope, name: []const u8) bool {
    return switch (scope.id) {
        .root => @as(*Root, @fieldParentPtr("base", scope)).contains(name),
        .block => @as(*Block, @fieldParentPtr("base", scope)).contains(name),
        .loop, .do_loop, .condition, .@"switch" => scope.parent.?.contains(name),
    };
}
pub fn appendNode(inner: *Scope, node: ast.Node) !void {
    var scope = inner;
    while (true) {
        switch (scope.id) {
            .root => {
                const root: *Root = @fieldParentPtr("base", scope);
                return root.nodes.append(root.translator.gpa, node);
            },
            .block => {
                const block: *Block = @fieldParentPtr("base", scope);
                return block.statements.append(block.translator.gpa, node);
            },
            else => scope = scope.parent.?,
        }
    }
}
pub fn skipVariableDiscard(inner: *Scope, name: []const u8) void {
    if (true) {
        return;
    }
    var scope = inner;
    while (true) {
        switch (scope.id) {
            .root => return,
            .block => {
                const block: *Block = @fieldParentPtr("base", scope);
                if (block.variable_discards.get(name)) |discard| {
                    discard.data.should_skip = true;
                    return;
                }
            },
            else => {},
        }
        scope = scope.parent.?;
    }
}
