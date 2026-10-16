const builtin = @import("builtin");
pub const base_application_id = "com.mitchellh.wasp";
pub const application_id = switch (builtin.mode) {
    .Debug, .ReleaseSafe => base_application_id ++ "-debug",
    .ReleaseFast, .ReleaseSmall => base_application_id,
};
pub const resource_path = "/com/mitchellh/wasp";
pub const object_path = switch (builtin.mode) {
    .Debug, .ReleaseSafe => resource_path ++ "_debug",
    .ReleaseFast, .ReleaseSmall => resource_path,
};
