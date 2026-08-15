const std = @import("std");
const r4os = @import("r4os");
const r4cc_core = @import("r4code_cc_core");
const r4pack_core = @import("r4code_pack_core");

const project_buffer_capacity: usize = 4096;
const manifest_arena_capacity: usize = 16 * 1024;
const plan_buffer_capacity: usize = 4096;
const log_capacity: usize = 8192;
const path_capacity: usize = 192;
// In-Guest-Grenzen fuer den Ressourcenbereich (0.61.12). Der Ladepuffer
// begrenzt die Summe der Bauquellen; der Pack-Ausgabepuffer bleibt
// source_buffer - reicht er nicht, ist das ein sichtbarer Fehler.
const resource_buffer_capacity: usize = 8 * 1024;
const max_guest_resources: usize = 16;

const log_dir = "C:\\SOFTWARE\\R4CODE\\LOGS";
const log_path = "C:\\SOFTWARE\\R4CODE\\LOGS\\R4BUILD.LOG";
const sdk_root = "C:\\R4OS\\SDK";
const c_toolchain_path = "C:\\R4OS\\SDK\\Toolchains\\C\\bin\\R4CC.R4X";
const c_toolchain_status_path = "C:\\R4OS\\SDK\\Toolchains\\C\\R4CC.STATUS";
const packer_path = "C:\\SOFTWARE\\R4CODE\\R4PACK.R4X";

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App{ .sys = r4_app.system() };
    const rc = app.run(trim(zSlice(app.sys.argsRaw())));
    _ = app.flushLog();
    return rc;
}

const Mode = enum {
    validate,
    plan,
    build,
};

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

const App = struct {
    sys: r4os.r4sys.Context,
    project_buffer: [project_buffer_capacity]u8 = undefined,
    plan_buffer: [plan_buffer_capacity]u8 = undefined,
    convert_buffer: [project_buffer_capacity]u8 = undefined,
    source_buffer: [r4cc_core.max_source_bytes]u8 = undefined,
    code_buffer: [r4cc_core.max_code_bytes]u8 = undefined,
    literal_buffer: [r4cc_core.max_literal_bytes]u8 = undefined,
    resource_buffer: [resource_buffer_capacity]u8 = undefined,
    log_buffer: [log_capacity]u8 = .{0} ** log_capacity,
    log_len: usize = 0,
    log_overflow: bool = false,

    fn run(self: *App, args: []const u8) i32 {
        self.resetLog();
        self.logLine("R4BUILD 0.58.33");
        if (args.len == 0 or equalsIgnoreCase(args, "HELP") or equalsIgnoreCase(args, "/?")) {
            self.printUsage();
            return 0;
        }

        const parsed = takeToken(args);
        if (parsed) |command| {
            if (equalsIgnoreCase(command.token, "/SELFTEST") or equalsIgnoreCase(command.token, "SELFTEST")) return self.selfTest();
            if (equalsIgnoreCase(command.token, "VALIDATE")) return self.runProjectCommand(.validate, trim(command.rest));
            if (equalsIgnoreCase(command.token, "PLAN")) return self.runProjectCommand(.plan, trim(command.rest));
            if (equalsIgnoreCase(command.token, "BUILD")) return self.runProjectCommand(.build, trim(command.rest));
            if (equalsIgnoreCase(command.token, "CONVERT")) return self.runConvert(trim(command.rest));
        }

        self.logLine("error: unknown command");
        self.printUsage();
        return 1;
    }

    fn printUsage(self: *App) void {
        self.logLine("usage:");
        self.logLine("  R4BUILD.R4X VALIDATE <module.R4MF>");
        self.logLine("  R4BUILD.R4X PLAN <module.R4MF>");
        self.logLine("  R4BUILD.R4X BUILD <module.R4MF>");
        self.logLine("  R4BUILD.R4X CONVERT <legacy.R4CP> <module.R4MF>");
        self.logLine("  R4BUILD.R4X /SELFTEST");
    }

    fn runProjectCommand(self: *App, mode: Mode, project_path: []const u8) i32 {
        if (project_path.len == 0) {
            self.logLine("error: missing project path");
            return 1;
        }
        if (endsWithIgnoreCase(project_path, ".R4CP")) {
            self.logLine("capability: historical R4CP requires explicit CONVERT");
            return 3;
        }
        if (!endsWithIgnoreCase(project_path, ".R4MF")) {
            self.logLine("error: current project path must end with .R4MF");
            return 1;
        }

        var manifest_arena: [manifest_arena_capacity]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(manifest_arena[0..]);
        const project = self.validateProject(project_path, fba.allocator()) orelse {
            self.logLine("validate result: FAILED");
            return 1;
        };
        self.logLine("validate result: OK");
        if (mode == .validate) return 0;

        if (!self.logPlan(project)) {
            self.logLine("plan result: FAILED");
            return 1;
        }
        self.logLine("plan result: OK");
        if (mode == .plan) return 0;

        if (!self.checkCapability(project)) return 3;

        if (!self.checkToolchain()) {
            self.logLine("build result: BLOCKED");
            return 2;
        }
        self.logLine("build plan result: READY");
        if (!self.buildProject(project_path, project)) {
            self.logLine("build result: FAILED");
            return 1;
        }
        self.logLine("build result: OK");
        return 0;
    }

    fn runConvert(self: *App, args: []const u8) i32 {
        const source_arg = takeToken(args) orelse {
            self.logLine("convert error: missing historical R4CP path");
            return 1;
        };
        const target_arg = takeToken(source_arg.rest) orelse {
            self.logLine("convert error: missing destination module.R4MF path");
            return 1;
        };
        if (trim(target_arg.rest).len != 0 or !endsWithIgnoreCase(source_arg.token, ".R4CP") or !endsWithIgnoreCase(target_arg.token, ".R4MF")) {
            self.logLine("convert error: expected CONVERT <legacy.R4CP> <module.R4MF>");
            return 1;
        }

        const source_text = self.readFile(source_arg.token, self.project_buffer[0..]) orelse {
            self.logLine("convert error: source missing or too large");
            return 1;
        };
        const legacy = r4os.r4cp.parse(source_text) catch |err| {
            self.logPair("convert error", r4os.r4cp.errorMessage(err));
            return 1;
        };
        const converted = r4os.r4cp_convert.render(legacy, self.convert_buffer[0..]);
        if (!converted.ok()) {
            self.logPair("convert capability", r4os.r4cp_convert.errorMessage(converted.err.?));
            return 3;
        }

        var manifest_arena: [manifest_arena_capacity]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(manifest_arena[0..]);
        _ = r4os.r4mf.parse(fba.allocator(), target_arg.token, converted.bytes) catch |err| {
            self.logPair("converted R4MF invalid", @errorName(err));
            return 1;
        };

        if (self.fileExists(target_arg.token)) {
            const existing = self.readFile(target_arg.token, self.plan_buffer[0..]) orelse {
                self.logLine("convert error: existing destination cannot be compared");
                return 1;
            };
            if (!equalsBytes(existing, converted.bytes)) {
                self.logLine("convert error: destination exists with different bytes");
                return 1;
            }
            self.logLine("convert result: OK (byte-identical no-op)");
            return 0;
        }

        var staged: [path_capacity]u8 = .{0} ** path_capacity;
        var staged_len: usize = 0;
        if (!appendText(staged[0..], &staged_len, target_arg.token) or !appendText(staged[0..], &staged_len, ".TMP")) {
            self.logLine("convert error: staged path too long");
            return 1;
        }
        _ = self.deleteFile(spanZ(staged[0..]));
        if (!self.writeFile(spanZ(staged[0..]), converted.bytes)) {
            self.logLine("convert error: staged write failed");
            return 1;
        }
        if (!self.renameFile(spanZ(staged[0..]), target_arg.token)) {
            _ = self.deleteFile(spanZ(staged[0..]));
            self.logLine("convert error: atomic rename failed");
            return 1;
        }
        self.logLine("convert result: OK");
        return 0;
    }

    fn validateProject(self: *App, project_path: []const u8, allocator: std.mem.Allocator) ?r4os.r4mf.Manifest {
        var ok = true;
        self.logLine("project validation");
        self.logPair("project", project_path);

        if (!self.dirExists(sdk_root)) {
            self.logLine("sdk missing: C:\\R4OS\\SDK");
            ok = false;
        } else {
            self.logLine("sdk: OK");
        }
        const text = self.readFile(project_path, self.project_buffer[0..]) orelse {
            self.logLine("project file missing or too large");
            return null;
        };
        const project = r4os.r4mf.parse(allocator, project_path, text) catch |err| {
            self.logPair("project invalid", @errorName(err));
            return null;
        };

        self.logPair("name", project.name);
        self.logPair("language", project.language.?.text());
        self.logPair("build profile", r4os.r4mf.buildProfileName(project.language.?, project.entry_mode.?, project.app_class.?));
        self.logPair("target", project.target);

        var project_dir: [path_capacity]u8 = .{0} ** path_capacity;
        if (!dirFromPath(project_path, project_dir[0..])) {
            self.logLine("project directory path too long");
            ok = false;
        }

        for (project.sources) |source| {
            var source_path: [path_capacity]u8 = .{0} ** path_capacity;
            if (!buildPathText(spanZ(project_dir[0..]), source, source_path[0..])) {
                self.logPair("source path too long", source);
                ok = false;
                continue;
            }
            if (self.fileExists(spanZ(source_path[0..]))) {
                self.logPair("source OK", source);
            } else {
                self.logPair("source missing", source);
                ok = false;
            }
        }

        self.logLine("export: R4XStart derived OK");
        self.logImportCount(project.imports.len);
        return if (ok) project else null;
    }

    fn logPlan(self: *App, project: r4os.r4mf.Manifest) bool {
        const rendered = r4os.r4mf.renderContractPlan(project, self.plan_buffer[0..]);
        if (!rendered.ok) return false;
        self.logLine("R4MF contract plan:");
        self.logWrite(rendered.bytes);
        return true;
    }

    fn checkCapability(self: *App, project: r4os.r4mf.Manifest) bool {
        if (project.language.? != .c) {
            self.logLine("capability: inside-R4OS compiler supports LANGUAGE=C only");
            return false;
        }
        if (project.entry_mode.? != .app) {
            self.logLine("capability: inside-R4OS compiler supports ENTRY_MODE=app only");
            return false;
        }
        if (project.sources.len != 1) {
            self.logLine("capability: inside-R4OS compiler supports exactly one C source");
            return false;
        }
        return switch (project.app_class.?) {
            .console => self.expectExactImports(project.imports, &.{"R4SYS:Query:1"}),
            .gui => self.expectExactImports(project.imports, &.{ "R4SYS:Query:1", "R4DESK:Query:1", "R4DRAW:Query:1" }),
            .service => blk: {
                self.logLine("capability: inside-R4OS compiler does not support service apps");
                break :blk false;
            },
        };
    }

    fn expectExactImports(self: *App, actual: []const []const u8, expected: []const []const u8) bool {
        if (actual.len == expected.len) {
            var all_equal = true;
            for (actual, expected) |left, right| all_equal = all_equal and equalsIgnoreCase(left, right);
            if (all_equal) return true;
        }
        self.logLine("capability: import set/order is not supported by the inside-R4OS packer");
        return false;
    }

    fn checkToolchain(self: *App) bool {
        var ok = true;
        if (!self.fileExists(c_toolchain_path)) {
            self.logLine("toolchain missing: C:\\R4OS\\SDK\\Toolchains\\C\\bin\\R4CC.R4X");
            ok = false;
        } else if (!self.queryToolchainStatus()) {
            ok = false;
        }
        if (!self.fileExists(packer_path)) {
            self.logLine("packer missing: C:\\SOFTWARE\\R4CODE\\R4PACK.R4X");
            ok = false;
        } else {
            self.logLine("packer: C:\\SOFTWARE\\R4CODE\\R4PACK.R4X OK");
        }
        return ok;
    }

    fn queryToolchainStatus(self: *App) bool {
        self.logLine("toolchain: C:\\R4OS\\SDK\\Toolchains\\C\\bin\\R4CC.R4X OK");
        const status_log = self.readFile(c_toolchain_status_path, self.plan_buffer[0..]) orelse {
            self.logLine("toolchain status missing: C:\\R4OS\\SDK\\Toolchains\\C\\R4CC.STATUS");
            return false;
        };
        if (!contains(status_log, "R4CC 0.58.33") or
            !contains(status_log, "target=x86_64-r4os-r4xstart") or
            !contains(status_log, "compile=R4X_C_App_Console,R4X_C_App_Desktop") or
            !contains(status_log, "host_fallback=disabled") or
            !contains(status_log, "status=OK"))
        {
            self.logLine("toolchain status invalid");
            return false;
        }
        self.logLine("toolchain status:");
        self.logIndentedLines(status_log);
        return true;
    }

    fn buildProject(self: *App, project_path: []const u8, project: r4os.r4mf.Manifest) bool {
        const is_desktop_ok = project.app_class.? == .gui;

        var project_dir: [path_capacity]u8 = .{0} ** path_capacity;
        if (!dirFromPath(project_path, project_dir[0..])) {
            self.logLine("R4BUILD error: project directory path too long");
            return false;
        }

        var source_path: [path_capacity]u8 = .{0} ** path_capacity;
        if (!buildPathText(spanZ(project_dir[0..]), project.sources[0], source_path[0..])) {
            self.logLine("R4BUILD error: source path too long");
            return false;
        }

        const source = self.readFile(spanZ(source_path[0..]), self.source_buffer[0..]) orelse {
            self.logPair("R4BUILD error: source read failed", spanZ(source_path[0..]));
            return false;
        };
        const compiled = if (is_desktop_ok)
            r4cc_core.compileDesktopOk(source, self.code_buffer[0..], self.literal_buffer[0..])
        else
            r4cc_core.compileConsole(source, self.code_buffer[0..], self.literal_buffer[0..]);
        if (!compiled.ok) {
            self.logWrite("R4CC error");
            if (compiled.line != 0) {
                self.logWrite(" line ");
                self.logU32(compiled.line);
            }
            self.logWrite(": ");
            self.logLine(r4cc_core.errorMessage(compiled.err.?));
            return false;
        }
        self.logPair("R4CC profile", r4os.r4mf.buildProfileName(project.language.?, project.entry_mode.?, project.app_class.?));
        self.logWrite("R4CC code bytes: ");
        self.logUsize(compiled.code.len);
        self.logWrite("\r\n");
        self.logPair("R4CC compiled text", compiled.text);
        self.logLine("R4CC compile: OK");

        // Ressourcen des Manifests laden (0.61.12): Reihenfolge ist bereits
        // die Vertragsreihenfolge (Icons nach Index, Help, Dateien).
        var resources: [max_guest_resources]r4pack_core.Resource = undefined;
        var resource_count: usize = 0;
        var resource_used: usize = 0;
        if (!self.loadProjectResources(spanZ(project_dir[0..]), project, resources[0..], &resource_count, &resource_used)) return false;

        self.logLine("R4PACK package: START");
        const package = if (is_desktop_ok)
            r4pack_core.packDesktopOkR4X(project.name, compiled.code, resources[0..resource_count], self.source_buffer[0..])
        else
            r4pack_core.packConsoleR4X(project.name, compiled.code, resources[0..resource_count], self.source_buffer[0..]);
        if (!package.ok) {
            self.logPair("R4PACK error", package.err);
            return false;
        }
        if (resource_count != 0) {
            self.logWrite("resources embedded: ");
            self.logUsize(resource_count);
            self.logWrite(" (");
            self.logUsize(resource_used);
            self.logWrite(" source bytes)\r\n");
        }
        for (project.imports) |entry| self.logPair("import from R4MF", entry);
        if (is_desktop_ok) {
            self.logLine("metadata: r4x.class=gui");
        } else {
            self.logLine("metadata: r4x.class=console");
        }
        self.logLine("export: R4XStart");
        self.logLine("metadata: r4x.start=r4xstart");
        self.logLine("metadata: generated_by=R4CC-r4mf-v2");
        self.logLine("R4PACK package: OK");

        var artifact_path: [path_capacity]u8 = .{0} ** path_capacity;
        var artifact_relative: [path_capacity]u8 = .{0} ** path_capacity;
        if (!buildArtifactPath(project.name, artifact_relative[0..]) or
            !buildPathText(spanZ(project_dir[0..]), spanZ(artifact_relative[0..]), artifact_path[0..]))
        {
            self.logLine("R4BUILD error: artifact path too long");
            return false;
        }
        if (!self.ensureParentDirectory(spanZ(artifact_path[0..]))) {
            self.logLine("R4BUILD error: artifact directory missing");
            return false;
        }
        if (!self.writeFile(spanZ(artifact_path[0..]), package.bytes)) {
            self.logLine("R4BUILD error: artifact write failed");
            return false;
        }
        self.logPair("artifact", spanZ(artifact_path[0..]));
        self.logWrite("artifact bytes: ");
        self.logUsize(package.bytes.len);
        self.logWrite("\r\n");
        return true;
    }

    fn logIndentedLines(self: *App, text: []const u8) void {
        var start: usize = 0;
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (i == text.len or text[i] == '\n') {
                var end = i;
                while (end > start and (text[end - 1] == '\r' or text[end - 1] == '\n')) end -= 1;
                if (end > start) {
                    self.logWrite("  ");
                    self.logLine(text[start..end]);
                }
                start = i + 1;
            }
        }
    }

    fn selfTest(self: *App) i32 {
        self.logLine("selftest");
        if (!self.writeSelftestProject("C:\\TEMP\\R4BUILD\\HELLOC", "module.R4MF", "main.c", selftest_console_project, selftest_console_source)) return 1;
        if (!self.writeSelftestProject("C:\\TEMP\\R4BUILD\\HELLOGUI", "module.R4MF", "main.c", selftest_desktop_project, selftest_desktop_source)) return 1;
        if (self.runProjectCommand(.validate, "C:\\TEMP\\R4BUILD\\HELLOC\\module.R4MF") != 0) return 1;
        if (self.runProjectCommand(.plan, "C:\\TEMP\\R4BUILD\\HELLOC\\module.R4MF") != 0) return 1;
        if (self.runProjectCommand(.validate, "C:\\TEMP\\R4BUILD\\HELLOGUI\\module.R4MF") != 0) return 1;
        if (self.runProjectCommand(.plan, "C:\\TEMP\\R4BUILD\\HELLOGUI\\module.R4MF") != 0) return 1;
        const build_rc = self.runProjectCommand(.build, "C:\\TEMP\\R4BUILD\\HELLOC\\module.R4MF");
        if (build_rc != 0) {
            self.logLine("selftest expected ready build toolchain");
            return 1;
        }
        if (!self.fileExists("C:\\TEMP\\R4BUILD\\HELLOC\\out\\HELLOC.R4X")) {
            self.logLine("selftest artifact missing");
            return 1;
        }
        const gui_build_rc = self.runProjectCommand(.build, "C:\\TEMP\\R4BUILD\\HELLOGUI\\module.R4MF");
        if (gui_build_rc != 0) {
            self.logLine("selftest expected ready desktop build toolchain");
            return 1;
        }
        if (!self.fileExists("C:\\TEMP\\R4BUILD\\HELLOGUI\\out\\HELLOGUI.R4X")) {
            self.logLine("selftest desktop artifact missing");
            return 1;
        }
        // Ressourcenparitaet (0.61.12): Ein Projekt mit Icon, Helpfile und
        // benannter Datei baut im Gast; der .rsrc-Bereich des Artefakts wird
        // byteweise gegen das nach dem R4M0-Vertrag selbst nachgerechnete
        // Soll verglichen. Host-Erzeuger und Gastpacker folgen demselben
        // freiheitsgradlosen Layout - beide Einzelnachweise zusammen ergeben
        // die Bytegleichheit.
        if (!self.writeSelftestProject("C:\\TEMP\\R4BUILD\\HELLORSRC", "module.R4MF", "main.c", selftest_rsrc_project, selftest_console_source)) return 1;
        if (!self.ensureDirectory("C:\\TEMP\\R4BUILD\\HELLORSRC\\Assets")) return 1;
        var selftest_ico: [selftest_ico_len]u8 = undefined;
        makeSelftestIco(selftest_ico[0..]);
        var selftest_data: [64]u8 = undefined;
        for (0..selftest_data.len) |index| selftest_data[index] = @intCast((index * 37 + 11) & 0xFF);
        if (!self.writeFile("C:\\TEMP\\R4BUILD\\HELLORSRC\\Assets\\Desktop.ico", selftest_ico[0..]) or
            !self.writeFile("C:\\TEMP\\R4BUILD\\HELLORSRC\\Assets\\Help.txt", selftest_help_with_bom) or
            !self.writeFile("C:\\TEMP\\R4BUILD\\HELLORSRC\\Assets\\Data.bin", selftest_data[0..]))
        {
            self.logLine("selftest resource asset write failed");
            return 1;
        }
        if (self.runProjectCommand(.build, "C:\\TEMP\\R4BUILD\\HELLORSRC\\module.R4MF") != 0) {
            self.logLine("selftest expected resource build to succeed");
            return 1;
        }
        if (!self.verifySelftestResources("C:\\TEMP\\R4BUILD\\HELLORSRC\\out\\HELLORSRC.R4X", selftest_ico[0..], selftest_data[0..])) return 1;

        if (!self.writeSelftestProject("C:\\TEMP\\R4BUILD\\UNSUP", "module.R4MF", "main.zig", selftest_unsupported_project, selftest_unsupported_source)) return 1;
        if (self.runProjectCommand(.validate, "C:\\TEMP\\R4BUILD\\UNSUP\\module.R4MF") != 0) return 1;
        if (self.runProjectCommand(.build, "C:\\TEMP\\R4BUILD\\UNSUP\\module.R4MF") != 3) {
            self.logLine("selftest expected explicit language capability error");
            return 1;
        }

        if (!self.writeSelftestProject("C:\\TEMP\\R4BUILD\\LEGACY", "OLD.R4CP", "main.c", selftest_legacy_project, selftest_console_source)) return 1;
        _ = self.deleteFile("C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF");
        _ = self.deleteFile("C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF.TMP");
        if (self.runConvert("C:\\TEMP\\R4BUILD\\LEGACY\\OLD.R4CP C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF") != 0 or
            self.runConvert("C:\\TEMP\\R4BUILD\\LEGACY\\OLD.R4CP C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF") != 0)
        {
            self.logLine("selftest converter failed");
            return 1;
        }
        if (self.runProjectCommand(.validate, "C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF") != 0) return 1;
        if (!self.writeFile("C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF", "conflicting destination\n") or
            self.runConvert("C:\\TEMP\\R4BUILD\\LEGACY\\OLD.R4CP C:\\TEMP\\R4BUILD\\LEGACY\\module.R4MF") == 0)
        {
            self.logLine("selftest converter conflict was not rejected");
            return 1;
        }
        const legacy_after_error = self.readFile("C:\\TEMP\\R4BUILD\\LEGACY\\OLD.R4CP", self.project_buffer[0..]) orelse return 1;
        if (!equalsBytes(legacy_after_error, selftest_legacy_project)) {
            self.logLine("selftest converter changed its source on error");
            return 1;
        }

        self.logLine("R4BUILD result: OK");
        return 0;
    }

    /// Liest das gebaute Artefakt und vergleicht seinen .rsrc-Bereich
    /// byteweise gegen das nach dem Vertrag nachgerechnete Soll.
    fn verifySelftestResources(self: *App, artifact_path: []const u8, ico: []const u8, data_bytes: []const u8) bool {
        const image = self.readFile(artifact_path, self.source_buffer[0..]) orelse {
            self.logLine("selftest resource artifact unreadable");
            return false;
        };
        const soll_resources = [_]r4pack_core.Resource{
            .{ .typ = r4pack_core.RSRC_TYPE_ICON, .bytes = ico },
            .{ .typ = r4pack_core.RSRC_TYPE_HELP, .bytes = selftest_help_with_bom },
            .{ .typ = r4pack_core.RSRC_TYPE_FILE, .name = "DATA.BIN", .bytes = data_bytes },
        };
        const soll_len = r4pack_core.resourceSectionLength(soll_resources[0..]);
        var soll: [4096]u8 = undefined;
        if (soll_len > soll.len) {
            self.logLine("selftest resource expectation too large");
            return false;
        }
        @memset(soll[0..soll_len], 0);
        r4pack_core.writeResourceSection(soll[0..soll_len], soll_resources[0..]);

        if (image.len < 64 or !equalsBytes(image[0..4], "R4M0")) {
            self.logLine("selftest resource artifact is not R4M0");
            return false;
        }
        const section_off = readU32(image, 16);
        const section_count = readU32(image, 20);
        var found = false;
        var index: usize = 0;
        while (index < section_count) : (index += 1) {
            const off = @as(usize, section_off) + index * 32;
            if (off + 32 > image.len) break;
            if (!equalsBytes(image[off .. off + 6], ".rsrc\x00")) continue;
            const file_off = readU32(image, off + 12);
            const file_size = readU32(image, off + 16);
            if (file_size != soll_len or @as(usize, file_off) + file_size > image.len) {
                self.logLine("selftest resource section size drifted");
                return false;
            }
            if (!equalsBytes(image[file_off .. file_off + file_size], soll[0..soll_len])) {
                self.logLine("selftest resource section bytes drifted");
                return false;
            }
            found = true;
        }
        if (!found) {
            self.logLine("selftest resource section missing");
            return false;
        }
        self.logLine("selftest resource area byte-identical to contract layout");
        return true;
    }

    fn loadProjectResources(self: *App, project_dir: []const u8, project: r4os.r4mf.Manifest, out: []r4pack_core.Resource, count: *usize, used: *usize) bool {
        count.* = 0;
        used.* = 0;
        for (project.icons) |relative| {
            if (!self.loadOneResource(project_dir, relative, r4pack_core.RSRC_TYPE_ICON, "", out, count, used)) return false;
        }
        if (project.help) |relative| {
            if (!self.loadOneResource(project_dir, relative, r4pack_core.RSRC_TYPE_HELP, "", out, count, used)) return false;
        }
        for (project.resources) |entry| {
            if (!self.loadOneResource(project_dir, entry.path, r4pack_core.RSRC_TYPE_FILE, entry.name, out, count, used)) return false;
        }
        return true;
    }

    fn loadOneResource(self: *App, project_dir: []const u8, relative: []const u8, typ: u16, name: []const u8, out: []r4pack_core.Resource, count: *usize, used: *usize) bool {
        if (count.* >= out.len) {
            self.logLine("R4BUILD error: too many resources for the in-guest build");
            return false;
        }
        // Manifestpfade nutzen '/', die Dateisystem-API '\\'.
        var canonical: [path_capacity]u8 = .{0} ** path_capacity;
        if (relative.len >= canonical.len) {
            self.logPair("R4BUILD error: resource path too long", relative);
            return false;
        }
        for (relative, 0..) |byte, index| canonical[index] = if (byte == '/') '\\' else byte;
        var resource_path: [path_capacity]u8 = .{0} ** path_capacity;
        if (!buildPathText(project_dir, spanZ(canonical[0..]), resource_path[0..])) {
            self.logPair("R4BUILD error: resource path too long", relative);
            return false;
        }
        const data = self.readFile(spanZ(resource_path[0..]), self.resource_buffer[used.*..]) orelse {
            self.logPair("R4BUILD error: resource read failed", spanZ(resource_path[0..]));
            return false;
        };
        out[count.*] = .{ .typ = typ, .name = name, .bytes = data };
        count.* += 1;
        used.* += data.len;
        return true;
    }

    fn writeSelftestProject(self: *App, dir: []const u8, project_file: []const u8, source_file: []const u8, project_text: []const u8, source_text: []const u8) bool {
        _ = self.ensureDirectory("C:\\TEMP");
        _ = self.ensureDirectory("C:\\TEMP\\R4BUILD");
        if (!self.ensureDirectory(dir)) return false;
        var src_dir: [path_capacity]u8 = .{0} ** path_capacity;
        if (!buildPathText(dir, "src", src_dir[0..]) or !self.ensureDirectory(spanZ(src_dir[0..]))) return false;

        var project_path: [path_capacity]u8 = .{0} ** path_capacity;
        var source_path: [path_capacity]u8 = .{0} ** path_capacity;
        if (!buildPathText(dir, project_file, project_path[0..]) or
            !buildPathText(spanZ(src_dir[0..]), source_file, source_path[0..]))
        {
            self.logLine("selftest path too long");
            return false;
        }
        if (!self.writeFile(spanZ(project_path[0..]), project_text) or !self.writeFile(spanZ(source_path[0..]), source_text)) {
            self.logLine("selftest write failed");
            return false;
        }
        return true;
    }

    fn readFile(self: *App, path: []const u8, out: []u8) ?[]const u8 {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return null;
        const read = self.sys.fileRead(zptr(path_z[0..]), out);
        if (read <= 0) return null;
        const len: usize = @intCast(read);
        if (len >= out.len) return null;
        return out[0..len];
    }

    fn writeFile(self: *App, path: []const u8, data: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        const written = self.sys.fileWrite(zptr(path_z[0..]), data);
        return written >= 0 and @as(usize, @intCast(written)) == data.len;
    }

    fn deleteFile(self: *App, path: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        return self.sys.fileDelete(zptr(path_z[0..])) >= 0;
    }

    fn renameFile(self: *App, old_path: []const u8, new_path: []const u8) bool {
        var old_z: [path_capacity]u8 = .{0} ** path_capacity;
        var new_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(old_z[0..], old_path) or !setZResult(new_z[0..], new_path)) return false;
        return self.sys.fileRename(zptr(old_z[0..]), zptr(new_z[0..])) >= 0;
    }

    fn fileExists(self: *App, path: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        if (self.sys.fileInfo(zptr(path_z[0..]))) |info| return info.exists != 0 and info.is_dir == 0;
        return false;
    }

    fn dirExists(self: *App, path: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        if (self.sys.fileInfo(zptr(path_z[0..]))) |info| return info.exists != 0 and info.is_dir != 0;
        return false;
    }

    fn ensureDirectory(self: *App, path: []const u8) bool {
        if (self.dirExists(path)) return true;
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        _ = self.sys.dirCreate(zptr(path_z[0..]));
        return self.dirExists(path);
    }

    fn ensureParentDirectory(self: *App, path: []const u8) bool {
        var dir: [path_capacity]u8 = .{0} ** path_capacity;
        if (!dirFromPath(path, dir[0..])) return false;
        return self.ensureDirectory(spanZ(dir[0..]));
    }

    fn resetLog(self: *App) void {
        self.log_len = 0;
        self.log_overflow = false;
        @memset(self.log_buffer[0..], 0);
    }

    fn logLine(self: *App, text: []const u8) void {
        self.logWrite(text);
        self.logWrite("\r\n");
    }

    fn logPair(self: *App, label: []const u8, value: []const u8) void {
        self.logWrite(label);
        self.logWrite(": ");
        self.logLine(value);
    }

    fn logImportCount(self: *App, count: usize) void {
        if (count == 1) {
            self.logLine("imports: 1");
        } else if (count == 2) {
            self.logLine("imports: 2");
        } else if (count == 3) {
            self.logLine("imports: 3");
        } else {
            self.logLine("imports: many");
        }
    }

    fn logWrite(self: *App, text: []const u8) void {
        self.sys.write(text);
        if (text.len == 0) return;
        if (self.log_len >= self.log_buffer.len) {
            self.log_overflow = true;
            return;
        }
        const writable = @min(text.len, self.log_buffer.len - self.log_len);
        if (writable < text.len) self.log_overflow = true;
        @memcpy(self.log_buffer[self.log_len .. self.log_len + writable], text[0..writable]);
        self.log_len += writable;
    }

    fn logUsize(self: *App, value: usize) void {
        self.logU64(@intCast(value));
    }

    fn logU32(self: *App, value: u32) void {
        self.logU64(value);
    }

    fn logU64(self: *App, value: u64) void {
        var buf: [20]u8 = undefined;
        var pos = buf.len;
        var n = value;
        if (n == 0) {
            self.logWrite("0");
            return;
        }
        while (n > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.logWrite(buf[pos..]);
    }

    fn flushLog(self: *App) bool {
        _ = self.ensureDirectory("C:\\SOFTWARE");
        _ = self.ensureDirectory("C:\\SOFTWARE\\R4CODE");
        _ = self.ensureDirectory(log_dir);
        if (self.log_overflow and self.log_len + 17 < self.log_buffer.len) {
            @memcpy(self.log_buffer[self.log_len .. self.log_len + 17], "\r\nlog truncated\r\n");
            self.log_len += 17;
        }
        const written = self.sys.fileWrite(log_path, self.log_buffer[0..self.log_len]);
        return written >= 0 and @as(usize, @intCast(written)) == self.log_len;
    }
};

fn takeToken(text: []const u8) ?Token {
    const value = trim(text);
    if (value.len == 0) return null;
    var i: usize = 0;
    while (i < value.len and !isSpace(value[i])) : (i += 1) {}
    return .{ .token = value[0..i], .rest = trim(value[i..]) };
}

fn buildArtifactPath(name: []const u8, out: []u8) bool {
    @memset(out, 0);
    var len: usize = 0;
    return appendText(out, &len, "out/") and appendText(out, &len, name) and appendText(out, &len, ".R4X");
}

fn dirFromPath(path: []const u8, out: []u8) bool {
    var split: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') split = i;
    }
    if (split == 0) return setZResult(out, ".");
    return setZResult(out, path[0..split]);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off]) | (@as(u32, bytes[off + 1]) << 8) | (@as(u32, bytes[off + 2]) << 16) | (@as(u32, bytes[off + 3]) << 24);
}

fn writeLe16(out: []u8, off: usize, value: u16) void {
    out[off] = @intCast(value & 0xFF);
    out[off + 1] = @intCast(value >> 8);
}

fn writeLe32(out: []u8, off: usize, value: u32) void {
    out[off] = @intCast(value & 0xFF);
    out[off + 1] = @intCast((value >> 8) & 0xFF);
    out[off + 2] = @intCast((value >> 16) & 0xFF);
    out[off + 3] = @intCast((value >> 24) & 0xFF);
}

/// Deterministisches 32x32-ICO in 8 bpp Palette fuer den Selbsttest:
/// ICONDIR (6) + Eintrag (16) + BITMAPINFOHEADER (40) + Palette (1024) +
/// Pixel (1024) + AND-Maske (128) = 2238 Bytes.
const selftest_ico_len: usize = 2238;
fn makeSelftestIco(out: []u8) void {
    @memset(out, 0);
    writeLe16(out, 2, 1);
    writeLe16(out, 4, 1);
    out[6] = 32;
    out[7] = 32;
    writeLe16(out, 10, 1);
    writeLe16(out, 12, 8);
    writeLe32(out, 14, 2216);
    writeLe32(out, 18, 22);
    writeLe32(out, 22, 40);
    writeLe32(out, 26, 32);
    writeLe32(out, 30, 64);
    writeLe16(out, 34, 1);
    writeLe16(out, 36, 8);
    var index: usize = 0;
    while (index < 256) : (index += 1) {
        const off = 62 + index * 4;
        const byte: u8 = @intCast(index);
        out[off] = byte;
        out[off + 1] = byte ^ 0x3C;
        out[off + 2] = byte ^ 0xC3;
    }
    var y: usize = 0;
    while (y < 32) : (y += 1) {
        var x: usize = 0;
        while (x < 32) : (x += 1) {
            out[1086 + y * 32 + x] = @intCast((x * 5 + y * 3) & 0xFF);
        }
    }
}

// Fuehrendes BOM absichtlich enthalten: Der Packer muss es beim Einbetten
// entfernen, wie es der Host-Erzeuger tut.
const selftest_help_with_bom = "\xEF\xBB\xBFHELLORSRC resource smoke helpfile.\r\nSecond line.\r\n";

const selftest_rsrc_project =
    \\R4OS_MODULE_MANIFEST=2
    \\KIND=R4X
    \\NAME=HELLORSRC
    \\VERSION=0.1.0
    \\LANGUAGE=C
    \\SOURCE=src/main.c
    \\ENTRY_MODE=app
    \\APP_CLASS=console
    \\TARGET=/R4OS/SOFTWARE/TERMINAL/HELLORSRC.R4X
    \\IMAGE_SCOPE=none
    \\IMPORT=R4SYS:Query:1
    \\ICON=Assets/Desktop.ico
    \\HELP=Assets/Help.txt
    \\RESOURCE=DATA.BIN:Assets/Data.bin
;

fn buildPathText(dir: []const u8, name: []const u8, out: []u8) bool {
    if (out.len == 0 or dir.len == 0 or name.len == 0) return false;
    @memset(out, 0);
    if (isAbsolutePath(name)) return setZResult(out, name);
    var len: usize = 0;
    if (!appendText(out, &len, dir)) return false;
    if (len > 0 and out[len - 1] != '\\' and out[len - 1] != '/') {
        if (!appendByte(out, &len, '\\')) return false;
    }
    return appendText(out, &len, name);
}

fn setZ(buffer: []u8, text: []const u8) void {
    @memset(buffer, 0);
    if (buffer.len == 0) return;
    const len = @min(buffer.len - 1, text.len);
    if (len > 0) @memcpy(buffer[0..len], text[0..len]);
    buffer[len] = 0;
}

fn setZResult(buffer: []u8, text: []const u8) bool {
    if (buffer.len == 0 or text.len + 1 > buffer.len) return false;
    setZ(buffer, text);
    return true;
}

fn zptr(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn zlen(buffer: []const u8) usize {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return len;
}

fn spanZ(buffer: []const u8) []const u8 {
    return buffer[0..zlen(buffer)];
}

fn appendText(out: []u8, len: *usize, text: []const u8) bool {
    if (len.* + text.len + 1 > out.len) return false;
    if (text.len > 0) @memcpy(out[len.* .. len.* + text.len], text);
    len.* += text.len;
    out[len.*] = 0;
    return true;
}

fn appendByte(out: []u8, len: *usize, ch: u8) bool {
    if (len.* + 2 > out.len) return false;
    out[len.*] = ch;
    len.* += 1;
    out[len.*] = 0;
    return true;
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn contains(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var i: usize = 0;
    while (i + needle.len <= value.len) : (i += 1) {
        if (equalsIgnoreCase(value[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn equalsBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return equalsIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 2 and path[1] == ':') return true;
    return path.len > 0 and (path[0] == '\\' or path[0] == '/');
}

const selftest_console_project =
    \\R4OS_MODULE_MANIFEST=2
    \\KIND=R4X
    \\NAME=HELLOC
    \\VERSION=0.1.0
    \\LANGUAGE=C
    \\SOURCE=src/main.c
    \\ENTRY_MODE=app
    \\APP_CLASS=console
    \\TARGET=/R4OS/SOFTWARE/TERMINAL/HELLOC.R4X
    \\IMAGE_SCOPE=none
    \\IMPORT=R4SYS:Query:1
;

const selftest_desktop_project =
    \\R4OS_MODULE_MANIFEST=2
    \\KIND=R4X
    \\NAME=HELLOGUI
    \\VERSION=0.1.0
    \\LANGUAGE=C
    \\SOURCE=src/main.c
    \\ENTRY_MODE=app
    \\APP_CLASS=gui
    \\TARGET=/SOFTWARE/HELLOGUI/HELLOGUI.R4X
    \\IMAGE_SCOPE=none
    \\IMPORT=R4SYS:Query:1
    \\IMPORT=R4DESK:Query:1
    \\IMPORT=R4DRAW:Query:1
;

const selftest_unsupported_project =
    \\R4OS_MODULE_MANIFEST=2
    \\KIND=R4X
    \\NAME=UNSUP
    \\VERSION=0.1.0
    \\LANGUAGE=Zig
    \\SOURCE=src/main.zig
    \\ENTRY_MODE=app
    \\APP_CLASS=console
    \\TARGET=/R4OS/SOFTWARE/TERMINAL/UNSUP.R4X
    \\IMAGE_SCOPE=none
    \\IMPORT=R4SYS:Query:1
;

const selftest_unsupported_source =
    \\pub fn main() void {}
;

const selftest_legacy_project =
    \\[Project]
    \\Name=OLDAPP
    \\ModuleKind=R4X
    \\Language=C
    \\BuildProfile=R4X_C_Console
    \\AppClass=console
    \\
    \\[Sources]
    \\Main=src/main.c
    \\
    \\[Imports]
    \\R4SYS=R4SYS:Query:1
    \\
    \\[Exports]
    \\Entry=R4XStart:.text:0:1
    \\
    \\[Output]
    \\Artifact=out/OLDAPP.R4X
    \\TargetPath=/R4OS/SOFTWARE/TERMINAL/OLDAPP.R4X
;

const selftest_console_source =
    \\#include <r4os/r4os.h>
    \\
    \\R4OS_TEXT(hello_message, "HELLO from R4BUILD selftest via R4CC");
    \\
    \\int32_t r4_app_main(R4App *app)
    \\{
    \\    return r4sys_write_line(&app->system, hello_message);
    \\}
;

const selftest_desktop_source =
    \\#include <r4os/r4os.h>
    \\
    \\R4OS_TEXT(window_title, "HELLOGUI");
    \\R4OS_TEXT(ok_label, "OK");
    \\R4OS_TEXT(message, "HELLO GUI from R4BUILD selftest");
    \\
    \\int32_t r4_app_main(R4App *app)
    \\{
    \\    R4Timer timers[1] = {{0}}; R4Window window; R4PaintContext paint;
    \\    if (!r4_window_open(app, timers, 1, &window)) return R4OS_ERR_NO_GROUP;
    \\    r4_window_set_title(&window, window_title); r4_window_set_minimum_size(&window, 260, 140);
    \\    if (!r4_window_begin_paint(&window, &paint)) return R4OS_ERR_NO_FN;
    \\    R4Canvas canvas = r4_paint_canvas(&paint);
    \\    r4_canvas_clear(canvas, 0x00C0C0C0); r4_canvas_rect(canvas, 84, 78, 72, 24, 0x00C0C0C0);
    \\    r4_canvas_text(canvas, 58, 50, message, 0x000000, 0x00FFFFFF); r4_canvas_text(canvas, 112, 86, ok_label, 0x000000, 0x00C0C0C0); r4_paint_present(&paint);
    \\    for (;;) { R4MessageNext next = r4_window_wait_message(&window, r4_timeout_forever());
    \\        if (next.state == R4_MESSAGE_NEXT_FAILED) return next.raw_code;
    \\        if (next.message.kind == R4_MESSAGE_CLOSE) return 0;
    \\        if (next.message.kind == R4_MESSAGE_MOUSE && next.message.value.mouse.action == R4_MOUSE_UP) return 0; }
    \\}
;
