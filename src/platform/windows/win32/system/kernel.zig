//! SHIM: system/kernel.zig from the generated package.
//!
//! `system/threading.zig` imports four small types from `system/kernel.zig`;
//! the real file is a cascade nothing else in gooey uses. Definitions copied
//! verbatim from the source package (`win32-25.0.28-preview`,
//! system/kernel.zig).

const arch = @import("../zig.zig").arch;

pub const LIST_ENTRY = extern struct {
    Flink: ?*LIST_ENTRY,
    Blink: ?*LIST_ENTRY,
};

pub const SINGLE_LIST_ENTRY = extern struct {
    Next: ?*SINGLE_LIST_ENTRY,
};

pub const PROCESSOR_NUMBER = extern struct {
    Group: u16,
    Number: u8,
    Reserved: u8,
};

pub const SLIST_ENTRY = extern struct {
    Next: ?*SLIST_ENTRY,
};

pub const SLIST_HEADER = switch (arch) {
    .Arm64 => extern union {
        Anonymous: extern struct {
            Alignment: u64,
            Region: u64,
        },
        HeaderArm64: extern struct {
            _bitfield1: u64,
            _bitfield2: u64,
        },
    },
    .X64 => extern union {
        Anonymous: extern struct {
            Alignment: u64,
            Region: u64,
        },
        HeaderX64: extern struct {
            _bitfield1: u64,
            _bitfield2: u64,
        },
    },
    .X86 => extern union {
        Alignment: u64,
        Anonymous: extern struct {
            Next: SINGLE_LIST_ENTRY,
            Depth: u16,
            CpuId: u16,
        },
    },
};
