const std = @import("std");
pub const Options = struct {
    pub const Artifact = enum {
        wasp,
        lib,
    };
    artifact: Artifact,
    oniguruma: bool,
    simd: bool,
    slow_runtime_safety: bool,
    c_abi: bool,
    features: Features = .{},
    version: std.SemanticVersion,
    pub const Features = packed struct {
        snapshot: bool = true,
        formatter: bool = true,
        selection: bool = true,
        search: bool = true,
        render_state: bool = true,
        input_encode: bool = true,
        color: bool = true,
        grid_introspection: bool = true,
        glyph_protocol: bool = true,
        kitty_graphics: bool = true,
        pub fn parse(list: []const u8) error{UnknownFeature}!Features {
            var result: Features = .{};
            var it = std.mem.splitAny(u8, list, ", ");
            while (it.next()) |raw| {
                if (raw.len == 0) continue;
                var name = raw;
                var enable = true;
                switch (name[0]) {
                    '+' => name = name[1..],
                    '-' => {
                        enable = false;
                        name = name[1..];
                    },
                    else => {},
                }
                if (name.len == 0) return error.UnknownFeature;
                if (std.mem.eql(u8, name, "all")) {
                    inline for (@typeInfo(Features).@"struct".fields) |field| {
                        @field(result, field.name) = enable;
                    }
                    continue;
                }
                var found = false;
                inline for (@typeInfo(Features).@"struct".fields) |field| {
                    if (eqlName(name, field.name)) {
                        @field(result, field.name) = enable;
                        found = true;
                    }
                }
                if (!found) return error.UnknownFeature;
            }
            return result;
        }
        fn eqlName(input: []const u8, name: []const u8) bool {
            if (input.len != name.len) return false;
            for (input, name) |a, b| {
                const norm: u8 = if (a == '-') '_' else a;
                if (norm != b) return false;
            }
            return true;
        }
        test "parse" {
            const testing = std.testing;
            const none: Features = @bitCast(
                @as(@typeInfo(Features).@"struct".backing_integer.?, 0),
            );
            try testing.expectEqual(Features{}, try Features.parse(""));
            try testing.expectEqual(
                Features{ .snapshot = false },
                try Features.parse("-snapshot"),
            );
            try testing.expectEqual(
                Features{ .snapshot = false, .formatter = false },
                try Features.parse("-snapshot,+render_state,-formatter,color"),
            );
            try testing.expectEqual(none, try Features.parse("-all"));
            try testing.expectEqual(Features{}, try Features.parse("-all,+all"));
            var render_only = none;
            render_only.render_state = true;
            try testing.expectEqual(
                render_only,
                try Features.parse("-all,+render-state"),
            );
            try testing.expectEqual(
                Features{ .input_encode = false, .grid_introspection = false },
                try Features.parse("-input-encode,-grid_introspection"),
            );
            try testing.expectEqual(
                Features{},
                try Features.parse("-snapshot,+snapshot"),
            );
            try testing.expectError(error.UnknownFeature, Features.parse("bogus"));
            try testing.expectError(error.UnknownFeature, Features.parse("-snapshot,-"));
        }
    };
    pub fn kittyGraphics(self: Options, target: std.Target) bool {
        if (target.os.tag == .freestanding) return false;
        return self.features.kitty_graphics;
    }
    pub fn add(
        self: Options,
        b: *std.Build,
        m: *std.Build.Module,
    ) void {
        const opts = b.addOptions();
        opts.addOption(Artifact, "artifact", self.artifact);
        opts.addOption(bool, "c_abi", self.c_abi);
        opts.addOption(bool, "oniguruma", self.oniguruma);
        opts.addOption(bool, "simd", self.simd);
        opts.addOption(bool, "slow_runtime_safety", self.slow_runtime_safety);
        opts.addOption(bool, "tmux_control_mode", self.oniguruma);
        const target = m.resolved_target.?.result;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            var value = @field(self.features, field.name);
            if (comptime std.mem.eql(u8, field.name, "kitty_graphics")) {
                value = self.kittyGraphics(target);
            }
            opts.addOption(bool, field.name, value);
        }
        opts.addOption(
            []const u8,
            "version_string",
            b.fmt(
                "{f}",
                .{self.version},
            ),
        );
        opts.addOption(usize, "version_major", self.version.major);
        opts.addOption(usize, "version_minor", self.version.minor);
        opts.addOption(usize, "version_patch", self.version.patch);
        opts.addOption(?[]const u8, "version_pre", self.version.pre);
        opts.addOption(?[]const u8, "version_build", self.version.build);
        m.addOptions("terminal_options", opts);
    }
};
test {
    _ = Options.Features;
}
