const std = @import("std");
const parser = @import("Parser.zig");
const State = parser.State;
const Action = parser.TransitionAction;
pub const table = genTable();
pub const Table = genTableType(false);
const OptionalTable = genTableType(true);
pub const Transition = struct {
    state: State,
    action: Action,
};
fn genTableType(comptime optional: bool) type {
    const max_u8 = std.math.maxInt(u8);
    const stateInfo = @typeInfo(State);
    const max_state = stateInfo.@"enum".fields.len;
    const Elem = if (optional) ?Transition else Transition;
    return [max_u8 + 1][max_state]Elem;
}
fn genTable() Table {
    @setEvalBranchQuota(20000);
    var result: OptionalTable = undefined;
    for (0..result.len) |i| {
        for (0..result[0].len) |j| {
            result[i][j] = null;
        }
    }
    const stateInfo = @typeInfo(State);
    inline for (stateInfo.@"enum".fields) |field| {
        const source: State = @enumFromInt(field.value);
        single(&result, 0x18, source, .ground, .execute);
        single(&result, 0x1A, source, .ground, .execute);
        range(&result, 0x80, 0x8F, source, .ground, .execute);
        range(&result, 0x91, 0x97, source, .ground, .execute);
        single(&result, 0x99, source, .ground, .execute);
        single(&result, 0x9A, source, .ground, .execute);
        single(&result, 0x9C, source, .ground, .none);
        single(&result, 0x1B, source, .escape, .none);
        single(&result, 0x98, source, .sos_pm_apc_string, .none);
        single(&result, 0x9E, source, .sos_pm_apc_string, .none);
        single(&result, 0x9F, source, .sos_pm_apc_string, .none);
        single(&result, 0x9B, source, .csi_entry, .none);
        single(&result, 0x90, source, .dcs_entry, .none);
        single(&result, 0x9D, source, .osc_string, .none);
    }
    {
        single(&result, 0x19, .ground, .ground, .execute);
        range(&result, 0, 0x17, .ground, .ground, .execute);
        range(&result, 0x1C, 0x1F, .ground, .ground, .execute);
        range(&result, 0x20, 0x7F, .ground, .ground, .print);
    }
    {
        const source = State.escape_intermediate;
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x30, 0x7E, source, .ground, .esc_dispatch);
    }
    {
        const source = State.sos_pm_apc_string;
        single(&result, 0x19, source, source, .apc_put);
        range(&result, 0, 0x17, source, source, .apc_put);
        range(&result, 0x1C, 0x1F, source, source, .apc_put);
        range(&result, 0x20, 0x7F, source, source, .apc_put);
    }
    {
        const source = State.escape;
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x30, 0x4F, source, .ground, .esc_dispatch);
        range(&result, 0x51, 0x57, source, .ground, .esc_dispatch);
        range(&result, 0x60, 0x7E, source, .ground, .esc_dispatch);
        single(&result, 0x59, source, .ground, .esc_dispatch);
        single(&result, 0x5A, source, .ground, .esc_dispatch);
        single(&result, 0x5C, source, .ground, .esc_dispatch);
        range(&result, 0x20, 0x2F, source, .escape_intermediate, .collect);
        single(&result, 0x58, source, .sos_pm_apc_string, .none);
        single(&result, 0x5E, source, .sos_pm_apc_string, .none);
        single(&result, 0x5F, source, .sos_pm_apc_string, .none);
        single(&result, 0x50, source, .dcs_entry, .none);
        single(&result, 0x5B, source, .csi_entry, .none);
        single(&result, 0x5D, source, .osc_string, .none);
    }
    {
        const source = State.dcs_entry;
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x20, 0x2F, source, .dcs_intermediate, .collect);
        single(&result, 0x3A, source, .dcs_ignore, .none);
        range(&result, 0x30, 0x39, source, .dcs_param, .param);
        single(&result, 0x3B, source, .dcs_param, .param);
        range(&result, 0x3C, 0x3F, source, .dcs_param, .collect);
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }
    {
        const source = State.dcs_intermediate;
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x30, 0x3F, source, .dcs_ignore, .none);
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }
    {
        const source = State.dcs_ignore;
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x80, 0xFF, source, source, .ignore);
    }
    {
        const source = State.dcs_param;
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x30, 0x39, source, source, .param);
        single(&result, 0x3B, source, source, .param);
        single(&result, 0x7F, source, source, .ignore);
        single(&result, 0x3A, source, .dcs_ignore, .none);
        range(&result, 0x3C, 0x3F, source, .dcs_ignore, .none);
        range(&result, 0x20, 0x2F, source, .dcs_intermediate, .collect);
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }
    {
        const source = State.dcs_passthrough;
        single(&result, 0x19, source, source, .put);
        range(&result, 0, 0x17, source, source, .put);
        range(&result, 0x1C, 0x1F, source, source, .put);
        range(&result, 0x20, 0x7E, source, source, .put);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x80, 0xFF, source, source, .put);
    }
    {
        const source = State.csi_param;
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x30, 0x39, source, source, .param);
        single(&result, 0x3A, source, source, .param);
        single(&result, 0x3B, source, source, .param);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);
        range(&result, 0x3C, 0x3F, source, .csi_ignore, .none);
        range(&result, 0x20, 0x2F, source, .csi_intermediate, .collect);
    }
    {
        const source = State.csi_ignore;
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x3F, source, source, .ignore);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x40, 0x7E, source, .ground, .none);
    }
    {
        const source = State.csi_intermediate;
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);
        range(&result, 0x30, 0x3F, source, .csi_ignore, .none);
    }
    {
        const source = State.csi_entry;
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        single(&result, 0x7F, source, source, .ignore);
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);
        single(&result, 0x3A, source, .csi_ignore, .none);
        range(&result, 0x20, 0x2F, source, .csi_intermediate, .collect);
        range(&result, 0x30, 0x39, source, .csi_param, .param);
        single(&result, 0x3B, source, .csi_param, .param);
        range(&result, 0x3C, 0x3F, source, .csi_param, .collect);
    }
    {
        const source = State.osc_string;
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x06, source, source, .ignore);
        range(&result, 0x08, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0xFF, source, source, .osc_put);
        single(&result, 0x07, source, .ground, .none);
    }
    var final: Table = undefined;
    for (0..final.len) |i| {
        for (0..final[0].len) |j| {
            final[i][j] = result[i][j] orelse transition(@enumFromInt(j), .none);
        }
    }
    return final;
}
fn single(t: *OptionalTable, c: u8, s0: State, s1: State, a: Action) void {
    const s0_int = @intFromEnum(s0);
    t[c][s0_int] = transition(s1, a);
}
fn range(t: *OptionalTable, from: u8, to: u8, s0: State, s1: State, a: Action) void {
    var i = from;
    while (i <= to) : (i += 1) {
        single(t, i, s0, s1, a);
        if (i == to) break;
    }
}
fn transition(state: State, action: Action) Transition {
    return .{ .state = state, .action = action };
}
test {
    _ = table;
}
test "dcs_passthrough: high bytes are payload data" {
    for (0x80..0x100) |c| {
        const entry = table[c][@intFromEnum(State.dcs_passthrough)];
        try std.testing.expectEqual(State.dcs_passthrough, entry.state);
        try std.testing.expectEqual(Action.put, entry.action);
    }
}
test "dcs_ignore: high bytes are ignored payload data" {
    for (0x80..0x100) |c| {
        const entry = table[c][@intFromEnum(State.dcs_ignore)];
        try std.testing.expectEqual(State.dcs_ignore, entry.state);
        try std.testing.expectEqual(Action.ignore, entry.action);
    }
}
test "dcs_passthrough: ESC, CAN, and SUB still exit" {
    const esc = table[0x1B][@intFromEnum(State.dcs_passthrough)];
    try std.testing.expectEqual(State.escape, esc.state);
    const can = table[0x18][@intFromEnum(State.dcs_passthrough)];
    try std.testing.expectEqual(State.ground, can.state);
    const sub = table[0x1A][@intFromEnum(State.dcs_passthrough)];
    try std.testing.expectEqual(State.ground, sub.state);
}
