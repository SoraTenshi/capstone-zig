const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "How the library shall be linked") orelse .static;
    const strip = b.option(bool, "strip", "Omit debug information");
    const pic = b.option(bool, "pie", "Produce Position Independent Code");

    const use_default_alloc = b.option(bool, "use-default-alloc", "Use default memory allocation functions") orelse true;
    const use_arch_registration = b.option(bool, "use-arch-registration", "Use explicit architecture registration") orelse false;
    const build_diet = b.option(bool, "build-diet", "Build diet library") orelse false;
    const x86_reduce = b.option(bool, "x86-reduce", "x86 with reduce instruction sets to minimize library") orelse false;
    const x86_att_disable = b.option(bool, "x86-att-disable", "Disable x86 AT&T syntax") orelse false;
    const osx_kernel_support = b.option(bool, "osx-kernel-support", "Support to embed Capstone into OS X Kernel extensions") orelse false;

    const supported_architectures_only_native = b.option(bool, "support-only-target-arch", "Only support the architecture of the build target") orelse false;
    const supported_architectures_list = b.option([]const SupportedArchitecture, "supported-architectures", "Specify which Architectures should be supported");

    var supported_architectures: std.EnumSet(SupportedArchitecture) = .{};
    if (supported_architectures_only_native) {
        if (SupportedArchitecture.fromArch(target.result.cpu.arch)) |arch| {
            supported_architectures.setPresent(arch, true);
        }
        for (supported_architectures_list orelse &.{}) |arch| {
            supported_architectures.setPresent(arch, true);
        }
    } else if (supported_architectures_list) |list| {
        for (list) |arch| {
            supported_architectures.setPresent(arch, true);
        }
    } else {
        supported_architectures = std.EnumSet(SupportedArchitecture).initFull();
    }

    const upstream = b.dependency("capstone", .{});

    const capstone = b.addLibrary(.{
        .name = "capstone",
        .linkage = linkage,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .pic = pic,
            .strip = strip,
            .link_libc = true,
        }),
    });
    b.installArtifact(capstone);
    capstone.addIncludePath(upstream.path("include"));
    capstone.installHeadersDirectory(upstream.path("include/capstone"), "capstone", .{});
    capstone.installHeader(upstream.path("include/platform.h"), "capstone/platform.h");
    capstone.addCSourceFiles(.{ .root = upstream.path(""), .files = common_sources });

    if (build_diet) capstone.root_module.addCMacro("CAPSTONE_DIET", "");
    if (use_default_alloc) capstone.root_module.addCMacro("CAPSTONE_USE_SYS_DYN_MEM", "");
    if (x86_reduce) capstone.root_module.addCMacro("CAPSTONE_X86_REDUCE", "");
    if (x86_att_disable) capstone.root_module.addCMacro("CAPSTONE_X86_ATT_DISABLE", "");
    if (osx_kernel_support) capstone.root_module.addCMacro("CAPSTONE_HAS_OSXKERNEL", "");
    if (optimize == .Debug) capstone.root_module.addCMacro("CAPSTONE_DEBUG", "");

    if (use_arch_registration) {
        capstone.root_module.addCMacro("CAPSTONE_USE_ARCH_REGISTRATION", "");
    } else {
        var it = supported_architectures.iterator();
        while (it.next()) |key| {
            // std.log.info("Enabling CAPSTONE_HAS_{s}", .{key.macroName()});
            capstone.root_module.addCMacro(b.fmt("CAPSTONE_HAS_{s}", .{key.macroName()}), "");
            capstone.addCSourceFiles(.{
                .root = upstream.path(b.fmt("arch/{s}", .{key.subdirectory()})),
                .files = key.sources(),
            });
            if (key == .x86 and !build_diet) {
                capstone.addCSourceFile(.{ .file = upstream.path("arch/X86/X86ATTInstPrinter.c") });
            }
        }
    }

    {
        const cstool = b.addExecutable(.{
            .name = "cstool",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .pic = pic,
                .strip = strip,
                .link_libc = true,
            }),
        });
        cstool.linkLibrary(capstone);
        cstool.addCSourceFiles(.{ .root = upstream.path("cstool"), .files = cstool_sources });
        cstool.addCSourceFile(.{ .file = upstream.path("cstool/getopt.c") });
        b.installArtifact(cstool);

        const run_cmd = b.addRunArtifact(cstool);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step("cstool", "Run cstool");
        run_step.dependOn(&run_cmd.step);
    }
}

pub const SupportedArchitecture = enum {
    arm,
    aarch64,
    mips,
    powerpc,
    sparc,
    systemZ,
    xcore,
    x86,
    /// Unsupported Zig Target
    tms320c64x,
    m68k,
    /// Unsupported Zig Target
    m680x,
    /// Unsupported Zig Target
    evm,
    /// Unsupported Zig Target
    mos65xx,
    wasm,
    bpf,
    riscv,
    /// Unsupported Zig Target
    sh,
    /// Unsupported Zig Target
    tricore,
    /// Unsupported Zig Target
    alpha,
    /// Unsupported Zig Target
    hppa,
    loongarch,
    xtensa,
    arc,

    pub fn fromArch(arch: std.Target.Cpu.Arch) ?SupportedArchitecture {
        return switch (arch) {
            .arm, .armeb, .thumb, .thumbeb => .arm,
            .aarch64, .aarch64_be => .aarch64,
            .m68k => .m68k,
            .mips, .mipsel, .mips64, .mips64el => .mips,
            .powerpc, .powerpcle, .powerpc64, .powerpc64le => .powerpc,
            .sparc, .sparc64 => .sparc,
            .s390x => .systemZ,
            .xcore => .xcore,
            .x86, .x86_64 => .x86,
            .wasm32, .wasm64 => .wasm,
            .bpfel, .bpfeb => .bpf,
            .riscv32, .riscv64 => .riscv,
            .loongarch32, .loongarch64 => .loongarch,
            .xtensa => .xtensa,
            .arc => .arc,

            else => null,
        };
    }

    fn macroName(self: SupportedArchitecture) []const u8 {
        return switch (self) {
            .arm => "ARM",
            .aarch64 => "AARCH64",
            .m68k => "M68K",
            .mips => "MIPS",
            .powerpc => "PPC",
            .sparc => "SPARC",
            .systemZ => "SYSTEMZ",
            .xcore => "XCORE",
            .x86 => "X86",
            .tms320c64x => "TMS320C64X",
            .m680x => "M680X",
            .evm => "EVM",
            .mos65xx => "MOS65XX",
            .wasm => "WASM",
            .bpf => "BPF",
            .riscv => "RISCV",
            .sh => "SH",
            .tricore => "TRICORE",
            .alpha => "ALPHA",
            .hppa => "HPPA",
            .loongarch => "LOONGARCH",
            .xtensa => "XTENSA",
            .arc => "ARC",
        };
    }

    fn subdirectory(self: SupportedArchitecture) []const u8 {
        return switch (self) {
            .arm => "ARM",
            .aarch64 => "AArch64",
            .mips => "Mips",
            .powerpc => "PowerPC",
            .sparc => "Sparc",
            .systemZ => "SystemZ",
            .xcore => "XCore",
            .x86 => "X86",
            .tms320c64x => "TMS320C64x",
            .m68k => "M68K",
            .m680x => "M680X",
            .evm => "EVM",
            .mos65xx => "MOS65XX",
            .wasm => "WASM",
            .bpf => "BPF",
            .riscv => "RISCV",
            .sh => "SH",
            .tricore => "TriCore",
            .alpha => "Alpha",
            .hppa => "HPPA",
            .loongarch => "LoongArch",
            .xtensa => "Xtensa",
            .arc => "ARC",
        };
    }

    fn sources(self: SupportedArchitecture) []const []const u8 {
        return switch (self) {
            .arm => &.{
                "ARMBaseInfo.c",
                "ARMDisassembler.c",
                "ARMDisassemblerExtension.c",
                "ARMInstPrinter.c",
                "ARMMapping.c",
                "ARMModule.c",
            },
            .aarch64 => &.{
                "AArch64BaseInfo.c",
                "AArch64Disassembler.c",
                "AArch64DisassemblerExtension.c",
                "AArch64InstPrinter.c",
                "AArch64Mapping.c",
                "AArch64Module.c",
            },
            .mips => &.{
                "MipsDisassembler.c",
                "MipsInstPrinter.c",
                "MipsMapping.c",
                "MipsModule.c",
            },
            .powerpc => &.{
                "PPCDisassembler.c",
                "PPCInstPrinter.c",
                "PPCMapping.c",
                "PPCModule.c",
            },
            .x86 => &.{
                "X86Disassembler.c",
                "X86DisassemblerDecoder.c",
                "X86IntelInstPrinter.c",
                "X86InstPrinterCommon.c",
                "X86Mapping.c",
                "X86Module.c",
                // separately handled
                // "X86ATTInstPrinter.c",
            },
            .sparc => &.{
                "SparcDisassembler.c",
                "SparcInstPrinter.c",
                "SparcMapping.c",
                "SparcModule.c",
            },
            .systemZ => &.{
                "SystemZDisassembler.c",
                "SystemZDisassemblerExtension.c",
                "SystemZInstPrinter.c",
                "SystemZMapping.c",
                "SystemZModule.c",
                "SystemZMCTargetDesc.c",
            },
            .xcore => &.{
                "XCoreDisassembler.c",
                "XCoreInstPrinter.c",
                "XCoreMapping.c",
                "XCoreModule.c",
            },
            .m68k => &.{
                "M68KDisassembler.c",
                "M68KInstPrinter.c",
                "M68KModule.c",
            },
            .tms320c64x => &.{
                "TMS320C64xDisassembler.c",
                "TMS320C64xInstPrinter.c",
                "TMS320C64xMapping.c",
                "TMS320C64xModule.c",
            },
            .m680x => &.{
                "M680XDisassembler.c",
                "M680XInstPrinter.c",
                "M680XModule.c",
            },
            .evm => &.{
                "EVMDisassembler.c",
                "EVMInstPrinter.c",
                "EVMMapping.c",
                "EVMModule.c",
            },
            .wasm => &.{
                "WASMDisassembler.c",
                "WASMInstPrinter.c",
                "WASMMapping.c",
                "WASMModule.c",
            },
            .mos65xx => &.{
                "MOS65XXModule.c",
                "MOS65XXDisassembler.c",
            },
            .bpf => &.{
                "BPFDisassembler.c",
                "BPFInstPrinter.c",
                "BPFMapping.c",
                "BPFModule.c",
            },
            .riscv => &.{
                "RISCVDisassembler.c",
                "RISCVInstPrinter.c",
                "RISCVMapping.c",
                "RISCVModule.c",
            },
            .sh => &.{
                "SHDisassembler.c",
                "SHInstPrinter.c",
                "SHModule.c",
            },
            .tricore => &.{
                "TriCoreDisassembler.c",
                "TriCoreInstPrinter.c",
                "TriCoreMapping.c",
                "TriCoreModule.c",
            },
            .alpha => &.{
                "AlphaDisassembler.c",
                "AlphaInstPrinter.c",
                "AlphaMapping.c",
                "AlphaModule.c",
            },
            .hppa => &.{
                "HPPADisassembler.c",
                "HPPAInstPrinter.c",
                "HPPAMapping.c",
                "HPPAModule.c",
            },
            .loongarch => &.{
                "LoongArchDisassembler.c",
                "LoongArchDisassemblerExtension.c",
                "LoongArchInstPrinter.c",
                "LoongArchMapping.c",
                "LoongArchModule.c",
            },
            .xtensa => &.{
                "XtensaDisassembler.c",
                "XtensaInstPrinter.c",
                "XtensaMapping.c",
                "XtensaModule.c",
            },
            .arc => &.{
                "ARCDisassembler.c",
                "ARCInstPrinter.c",
                "ARCMapping.c",
                "ARCModule.c",
            },
        };
    }
};

const common_sources: []const []const u8 = &.{
    "cs.c",
    "Mapping.c",
    "MCInst.c",
    "MCInstrDesc.c",
    "MCInstPrinter.c",
    "MCRegisterInfo.c",
    "SStream.c",
    "utils.c",
};

const cstool_sources: []const []const u8 = &.{
    "cstool.c",
    "cstool_aarch64.c",
    "cstool_alpha.c",
    "cstool_arc.c",
    "cstool_arm.c",
    "cstool_bpf.c",
    "cstool_evm.c",
    "cstool_hppa.c",
    "cstool_loongarch.c",
    "cstool_m680x.c",
    "cstool_m68k.c",
    "cstool_mips.c",
    "cstool_mos65xx.c",
    "cstool_powerpc.c",
    "cstool_riscv.c",
    "cstool_sh.c",
    "cstool_sparc.c",
    "cstool_systemz.c",
    "cstool_tms320c64x.c",
    "cstool_tricore.c",
    "cstool_wasm.c",
    "cstool_x86.c",
    "cstool_xcore.c",
    "cstool_xtensa.c",
};
