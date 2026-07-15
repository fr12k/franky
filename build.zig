const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Null = let Zig pick the default for the target. On macOS, LLD cannot
    // link Mach-O in Zig 0.16+ (`using LLD to link macho files is
    // unsupported`), so we force it off there unless the user explicitly
    // opts back in with -Duse-lld=true.
    const use_llvm = b.option(bool, "use-llvm", "Use the LLVM backend (default: target-dependent)");
    const use_lld_opt = b.option(bool, "use-lld", "Use LLD for linking (default: false on macOS, target-dependent elsewhere)");

    const use_lld: ?bool = if (target.result.os.tag == .macos and use_lld_opt == null)
        false
    else
        use_lld_opt;

    const regex_pathological = b.option(bool, "regex-pathological", "Run expensive regex pathological-pattern test (default: false)") orelse false;

    const embedded_settings_json = @embedFile("settings.json");
    const franky_options = b.addOptions();
    franky_options.addOption([]const u8, "embedded_settings_json", embedded_settings_json);

    // Version info — injected by goreleaser via -Dversion / -Dcommit / -Ddate.
    // Falls back to defaults when building with plain `zig build`.
    franky_options.addOption(
        []const u8,
        "version",
        b.option([]const u8, "version", "Version string (set by goreleaser)") orelse "dev",
    );
    franky_options.addOption(
        []const u8,
        "commit",
        b.option([]const u8, "commit", "Git commit SHA (set by goreleaser)") orelse "unknown",
    );
    franky_options.addOption(
        []const u8,
        "date",
        b.option([]const u8, "date", "Build date in RFC3339 (set by goreleaser)") orelse "unknown",
    );

    // v1.28.1 — compile-time TLS verification skip. When true, TLS
    // encryption is still active but certificate chain and hostname
    // verification are skipped (no CA bundle needed). Set via:
    //   zig build -Dtls-insecure=true
    // Useful in container environments that lack CA certificates.
    franky_options.addOption(
        bool,
        "tls_insecure",
        b.option(bool, "tls-insecure", "Skip TLS certificate verification (keep encryption, skip CA bundle)") orelse false,
    );
    franky_options.addOption(
        bool,
        "regex_pathological_test",
        regex_pathological,
    );

    // ── zompress dependency ────────────────────────────────────────
    const zompress_dep = b.dependency("zompress", .{
        .target = target,
        .optimize = optimize,
    });
    const zompress_module = zompress_dep.module("zompress");

    // Public module — exposed to dependents via `b.dependency("franky").module("franky")`.
    // The internal binary still imports through the same `franky_module`
    // so there's only one definition. This is what makes franky-do (and
    // any future sibling project) able to consume `franky.sdk`.
    const franky_module = b.addModule("franky", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    franky_module.addOptions("build_options", franky_options);
    franky_module.addImport("zompress", zompress_module);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/bin/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("franky", franky_module);
    exe_module.addImport("zompress", zompress_module);

    const exe = b.addExecutable(.{
        .name = "franky",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the franky CLI").dependOn(&run_cmd.step);

    // `zig build gen-models` — regenerate the §H.3 catalog by polling
    // each provider's models endpoint. Pass-through args via `-- …`.
    // Implements franky-spec-v2.md §1.4 — see `src/bin/gen_models.zig`
    // for the CLI surface.
    const gen_models_module = b.createModule(.{
        .root_source_file = b.path("src/bin/gen_models.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_models_module.addImport("franky", franky_module);

    const gen_models_exe = b.addExecutable(.{
        .name = "franky-gen-models",
        .root_module = gen_models_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const gen_models_run = b.addRunArtifact(gen_models_exe);
    gen_models_run.addPassthruArgs();
    b.step("gen-models", "Regenerate models.json by polling provider endpoints").dependOn(&gen_models_run.step);

    // `zig build doctor` — cross-session self-improvement analyzer.
    // See `coding/improvement.zig` for the heuristics; this binary
    // is the CLI wrapper that walks `~/.franky/diagnostics/` and
    // writes a feature-request-shaped markdown report to
    // `~/.franky/improvements/<model>/<unix_ms>.md`.
    const doctor_module = b.createModule(.{
        .root_source_file = b.path("src/bin/franky_doctor.zig"),
        .target = target,
        .optimize = optimize,
    });
    doctor_module.addImport("franky", franky_module);
    const doctor_exe = b.addExecutable(.{
        .name = "franky-doctor",
        .root_module = doctor_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const doctor_run = b.addRunArtifact(doctor_exe);
    doctor_run.addPassthruArgs();
    b.step("doctor", "Run cross-session self-improvement analyzer").dependOn(&doctor_run.step);

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "embedded_settings_json", "{}");
    test_options.addOption([]const u8, "version", "test");
    test_options.addOption([]const u8, "commit", "test");
    test_options.addOption([]const u8, "date", "test");
    test_options.addOption(bool, "tls_insecure", false);
    test_options.addOption(bool, "regex_pathological_test", regex_pathological);
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", test_options);
    test_module.addImport("zompress", zompress_module);
    const unit_tests = b.addTest(.{
        .name = "franky-test",
        .root_module = test_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit + integration tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build check-spec-anchors` — verify every §-anchor referenced
    // from source resolves to a heading in docs/spec/v{1,2}.md. Catches
    // dead pointers when sections are renamed or removed (per the
    // "Cross-references survive when they target stable identifiers"
    // discipline in docs/reference/spec-management.md).
    const check_anchors_module = b.createModule(.{
        .root_source_file = b.path("src/bin/check_spec_anchors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const check_anchors_exe = b.addExecutable(.{
        .name = "franky-check-spec-anchors",
        .root_module = check_anchors_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const check_anchors_run = b.addRunArtifact(check_anchors_exe);
    const anchor_step = b.step("check-spec-anchors", "Verify source §-references resolve to spec headings");
    anchor_step.dependOn(&check_anchors_run.step);
    test_step.dependOn(&check_anchors_run.step);

    // `zig build check-doc-links` — verify every relative Markdown link in
    // docs/spec/v*.md resolves to an existing file. Catches broken paths
    // when design docs move between open/, decided/, and archive/design/.
    const check_links_module = b.createModule(.{
        .root_source_file = b.path("src/bin/check_doc_links.zig"),
        .target = target,
        .optimize = optimize,
    });
    const check_links_exe = b.addExecutable(.{
        .name = "franky-check-doc-links",
        .root_module = check_links_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const check_links_run = b.addRunArtifact(check_links_exe);
    const links_step = b.step("check-doc-links", "Verify relative links in docs/spec/v*.md resolve to existing files");
    links_step.dependOn(&check_links_run.step);
    test_step.dependOn(&check_links_run.step);

    // `zig build check-doc` — composite: spec-anchor check + doc-link check.
    const check_doc_step = b.step("check-doc", "Run check-spec-anchors and check-doc-links");
    check_doc_step.dependOn(&check_anchors_run.step);
    check_doc_step.dependOn(&check_links_run.step);

    const integration_files = [_][]const u8{
        "test/agent_loop_test.zig",
        "test/agent_class_test.zig",
        "test/gitignore_test.zig",
        "test/parallel_tools_test.zig",
        "test/kitchen_sink_test.zig",
        "test/replay_test.zig",
        "test/mode_test.zig",
        "test/public_api_hash_test.zig",
        "test/compression_test.zig",
    };
    for (integration_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("franky", test_module);
        const name = std.fs.path.stem(path);
        const t = b.addTest(.{
            .name = b.fmt("franky-{s}", .{name}),
            .root_module = mod,
            .use_llvm = use_llvm,
            .use_lld = use_lld,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // `zig build test-profile` — build (do not run) FP-preserved test
    // binaries to zig-out/bin/franky-{test,<integration>_test}. See
    // docs/spec/v2.md §8.1 for the rationale: external profilers
    // (perf --call-graph fp) need %rbp preserved, which the
    // optimiser otherwise strips above Debug. The regular `zig build
    // test` path is unchanged — these are separate modules / artifacts.
    //
    // `-Dprofile-filter=PATTERN` (optional) narrows the captured test
    // set at compile time. Zig 0.17's standalone test binary does not
    // accept --test-filter at runtime, so the filter must be baked
    // into the binary here. Multiple uses of -Dprofile-filter accumulate.
    const profile_filters = b.option(
        []const []const u8,
        "profile-filter",
        "Narrow the FP-preserved test binaries to tests matching PATTERN (compile-time; repeatable)",
    ) orelse &[_][]const u8{};
    // `link_libc = true` is required for heaptrack: it injects via
    // LD_PRELOAD, which is a no-op on statically-linked binaries (no
    // dynamic loader, no preload). Without this the memory pipeline
    // deadlocks — the binary never opens the heaptrack FIFO, and
    // `heaptrack_interpret < $fifo` blocks forever waiting for a writer.
    const profile_test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = false,
        .link_libc = true,
    });
    profile_test_module.addOptions("build_options", franky_options);
    const profile_unit_tests = b.addTest(.{
        .name = "franky-test",
        .root_module = profile_test_module,
        .filters = profile_filters,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const test_profile_step = b.step(
        "test-profile",
        "Build profilable test binaries (FP-preserved) into zig-out/bin (no run)",
    );
    test_profile_step.dependOn(&b.addInstallArtifact(profile_unit_tests, .{}).step);
    for (integration_files) |path| {
        const profile_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = false,
            .link_libc = true,
        });
        profile_mod.addImport("franky", profile_test_module);
        const name = std.fs.path.stem(path);
        const profile_t = b.addTest(.{
            .name = b.fmt("franky-{s}", .{name}),
            .root_module = profile_mod,
            .filters = profile_filters,
            .use_llvm = use_llvm,
            .use_lld = use_lld,
        });
        test_profile_step.dependOn(&b.addInstallArtifact(profile_t, .{}).step);
    }

    // `zig build profile -- [options]` — drive perf + heaptrack +
    // inferno against the FP-preserved test binaries to produce CPU
    // and memory flamegraphs. See `src/bin/franky_profile.zig` for
    // the CLI surface and docs/spec/v2.md §8.2 for the spec
    // (long-form how-to: docs/archive/profiling_guide.md).
    const profile_driver_module = b.createModule(.{
        .root_source_file = b.path("src/bin/franky_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    profile_driver_module.addImport("franky", franky_module);
    const profile_driver_exe = b.addExecutable(.{
        .name = "franky-profile",
        .root_module = profile_driver_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const profile_driver_run = b.addRunArtifact(profile_driver_exe);
    profile_driver_run.step.dependOn(test_profile_step);
    profile_driver_run.addPassthruArgs();
    b.step("profile", "Capture CPU + memory flamegraphs from the test suite").dependOn(&profile_driver_run.step);
}
