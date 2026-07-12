const std = @import("std");
const Io = std.Io;

const Dependency = struct {
    name: []const u8,
    path: []const u8,
};

const Frontmatter = struct {
    dependencies: std.ArrayList(Dependency),
    flags: std.ArrayList([]const u8),
};

const BlockInfo = struct {
    code: []const u8,
    is_runnable: bool,
    block_index: usize,
};

const Segment = struct {
    is_placeholder: bool,
    content: []const u8,
    block_index: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var input_file: ?[]const u8 = null;
    var cli_deps: std.ArrayList(Dependency) = .empty;
    var cli_flags: std.ArrayList([]const u8) = .empty;
    var keep_temp = false;

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--dep")) {
            if (arg_idx + 1 >= args.len) {
                std.debug.print("Error: --dep requires an argument in the format name=path\n", .{});
                std.process.exit(1);
            }
            arg_idx += 1;
            const dep_val = args[arg_idx];
            if (std.mem.indexOfScalar(u8, dep_val, '=')) |eq_idx| {
                const name = dep_val[0..eq_idx];
                const path_val = dep_val[eq_idx + 1 ..];
                try cli_deps.append(arena, .{ .name = name, .path = path_val });
            } else {
                std.debug.print("Error: --dep argument must be in format name=path\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--flag")) {
            if (arg_idx + 1 >= args.len) {
                std.debug.print("Error: --flag requires an argument\n", .{});
                std.process.exit(1);
            }
            arg_idx += 1;
            try cli_flags.append(arena, args[arg_idx]);
        } else if (std.mem.eql(u8, arg, "--keep")) {
            keep_temp = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            if (input_file != null) {
                std.debug.print("Error: Multiple input files specified\n", .{});
                std.process.exit(1);
            }
            input_file = arg;
        }
    }

    if (input_file == null) {
        std.debug.print("Usage: ztangle [--keep] [--dep name=path] [--flag flag] <input_file>\n", .{});
        std.process.exit(1);
    }

    // Resolve the input file's directory
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const abs_input_path = try resolvePath(arena, cwd_path, input_file.?);
    const input_file_dir = std.fs.path.dirname(abs_input_path) orelse cwd_path;

    // Read the MDX file content
    const file = std.Io.Dir.openFileAbsolute(io, abs_input_path, .{}) catch |err| {
        std.debug.print("Error: Failed to open input file '{s}': {}\n", .{ abs_input_path, err });
        std.process.exit(1);
    };
    const file_stat = try file.stat(io);
    const content = try arena.alloc(u8, file_stat.size);
    const bytes_read = try file.readPositionalAll(io, content, 0);
    if (bytes_read != file_stat.size) {
        std.debug.print("Error: Short read of input file\n", .{});
        std.process.exit(1);
    }
    file.close(io);

    // Parse YAML frontmatter
    const frontmatter = try parseFrontmatter(arena, content);

    // Merge CLI and frontmatter dependencies
    var merged_deps: std.ArrayList(Dependency) = .empty;
    try merged_deps.appendSlice(arena, cli_deps.items);
    for (frontmatter.dependencies.items) |f_dep| {
        var overridden = false;
        for (cli_deps.items) |c_dep| {
            if (std.mem.eql(u8, c_dep.name, f_dep.name)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            try merged_deps.append(arena, f_dep);
        }
    }

    // Merge CLI and frontmatter flags
    var merged_flags: std.ArrayList([]const u8) = .empty;
    try merged_flags.appendSlice(arena, cli_flags.items);
    try merged_flags.appendSlice(arena, frontmatter.flags.items);

    // Read lines
    var input_lines: std.ArrayList([]const u8) = .empty;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        try input_lines.append(arena, line);
    }

    // Parse structure into segments and collect blocks
    var segments: std.ArrayList(Segment) = .empty;
    var accumulated_blocks: std.ArrayList(BlockInfo) = .empty;
    var block_count: usize = 0;

    var i: usize = 0;
    while (i < input_lines.items.len) {
        const line = input_lines.items[i];
        const trimmed_line = std.mem.trimStart(u8, line, " \t\r");
        
        if (std.mem.eql(u8, std.mem.trim(u8, trimmed_line, " \r\t"), "```zig")) {
            try segments.append(arena, .{ .is_placeholder = false, .content = line });
            
            const code_start = i + 1;
            i += 1;
            while (i < input_lines.items.len) {
                const code_line = input_lines.items[i];
                try segments.append(arena, .{ .is_placeholder = false, .content = code_line });
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, code_line, " \t\r"), "```")) {
                    break;
                }
                i += 1;
            }
            
            const code_end = i;
            
            var code_buf: std.ArrayList(u8) = .empty;
            var j = code_start;
            while (j < code_end) : (j += 1) {
                try code_buf.appendSlice(arena, input_lines.items[j]);
                try code_buf.append(arena, '\n');
            }
            const code_str = try code_buf.toOwnedSlice(arena);
            block_count += 1;
            
            // Look ahead for placeholder or result block
            i += 1;
            var placeholder_start = i;
            while (placeholder_start < input_lines.items.len) {
                const next_line = input_lines.items[placeholder_start];
                if (std.mem.trim(u8, next_line, " \r\t").len > 0) {
                    break;
                }
                try segments.append(arena, .{ .is_placeholder = false, .content = next_line });
                placeholder_start += 1;
            }
            
            var is_runnable = false;
            var is_placeholder = false;
            var is_existing_result = false;
            var existing_end_idx: usize = 0;
            
            if (placeholder_start < input_lines.items.len) {
                const next_line = input_lines.items[placeholder_start];
                const trimmed_next = std.mem.trim(u8, next_line, " \r\t");
                
                if (std.mem.eql(u8, trimmed_next, "{{zig code reuslt holder}}") or
                    std.mem.eql(u8, trimmed_next, "{{zig code result holder}}")) {
                    is_runnable = true;
                    is_placeholder = true;
                } else if (std.mem.startsWith(u8, trimmed_next, "<!-- zig-result-start -->")) {
                    is_runnable = true;
                    is_existing_result = true;
                    var find_end = placeholder_start;
                    while (find_end < input_lines.items.len) : (find_end += 1) {
                        const check_line = input_lines.items[find_end];
                        if (std.mem.indexOf(u8, check_line, "<!-- zig-result-end -->") != null) {
                            existing_end_idx = find_end;
                            break;
                        }
                    }
                    if (existing_end_idx == 0) {
                        is_runnable = false;
                    }
                } else if (std.mem.eql(u8, trimmed_next, "<!-- zig-result-start --><!-- zig-result-end -->") or
                           std.mem.eql(u8, trimmed_next, "<!--zig-result-start--><!--zig-result-end-->") or
                           std.mem.eql(u8, trimmed_next, "<!-- zig-result-start -->\n<!-- zig-result-end -->")) {
                    is_runnable = true;
                    is_placeholder = true;
                }
            }
            
            try accumulated_blocks.append(arena, .{
                .code = code_str,
                .is_runnable = is_runnable,
                .block_index = block_count,
            });
            
            if (is_runnable) {
                try segments.append(arena, .{
                    .is_placeholder = true,
                    .content = "",
                    .block_index = block_count,
                });
                
                if (is_placeholder) {
                    i = placeholder_start + 1;
                } else if (is_existing_result) {
                    i = existing_end_idx + 1;
                }
            } else {
                i = placeholder_start;
            }
        } else {
            try segments.append(arena, .{ .is_placeholder = false, .content = line });
            i += 1;
        }
    }

    var output: std.ArrayList(u8) = .empty;

    // Check if we need to compile and run
    var total_runnable: usize = 0;
    for (accumulated_blocks.items) |block| {
        if (block.is_runnable) total_runnable += 1;
    }

    if (total_runnable > 0) {
        std.debug.print("Compiling and executing notebook ({} runnable blocks)...\n", .{total_runnable});
        const run_output = try runAllZigBlocks(arena, io, init.environ_map, accumulated_blocks, merged_deps, merged_flags, input_file_dir, keep_temp);

        // Reconstruct the file with the output substituted
        for (segments.items) |seg| {
            if (seg.is_placeholder) {
                const section_output = try extractSectionOutput(arena, run_output, seg.block_index);
                
                try output.appendSlice(arena, "<!-- zig-result-start -->\n");
                try output.appendSlice(arena, "```\n");
                try output.appendSlice(arena, section_output);
                if (section_output.len == 0 or section_output[section_output.len - 1] != '\n') {
                    try output.append(arena, '\n');
                }
                try output.appendSlice(arena, "```\n");
                try output.appendSlice(arena, "<!-- zig-result-end -->\n");
            } else {
                try output.appendSlice(arena, seg.content);
                try output.append(arena, '\n');
            }
        }
    } else {
        // Just write segments back unchanged
        for (segments.items) |seg| {
            try output.appendSlice(arena, seg.content);
            try output.append(arena, '\n');
        }
    }

    // Write back the expanded content
    const write_file = try std.Io.Dir.createFileAbsolute(io, abs_input_path, .{ .truncate = true });
    try write_file.writePositionalAll(io, output.items, 0);
    write_file.close(io);

    std.debug.print("Successfully expanded MDX file: {s}\n", .{abs_input_path});
}

fn resolvePath(allocator: std.mem.Allocator, base_dir: []const u8, relative_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative_path)) {
        return try allocator.dupe(u8, relative_path);
    }
    return try std.fs.path.resolve(allocator, &.{ base_dir, relative_path });
}

fn findModuleRoot(allocator: std.mem.Allocator, io: std.Io, dep_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, dep_path, ".zig")) {
        return try allocator.dupe(u8, dep_path);
    }
    const candidates = [_][]const u8{ "src/root.zig", "src/main.zig" };
    for (candidates) |candidate| {
        const full_candidate = try std.fs.path.join(allocator, &.{ dep_path, candidate });
        defer allocator.free(full_candidate);
        
        // Open to verify file existence
        var f = std.Io.Dir.openFileAbsolute(io, full_candidate, .{}) catch continue;
        f.close(io);
        return try allocator.dupe(u8, full_candidate);
    }
    return try allocator.dupe(u8, dep_path);
}

fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) !Frontmatter {
    var deps: std.ArrayList(Dependency) = .empty;
    var flags: std.ArrayList([]const u8) = .empty;
    
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first_line = lines.next() orelse return Frontmatter{ .dependencies = deps, .flags = flags };
    if (!std.mem.eql(u8, std.mem.trim(u8, first_line, " \r\t"), "---")) {
        return Frontmatter{ .dependencies = deps, .flags = flags };
    }
    
    var in_dependencies = false;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, trimmed, "---")) {
            break;
        }
        
        if (std.mem.startsWith(u8, trimmed, "zig_dependencies:")) {
            in_dependencies = true;
            continue;
        }
        
        if (std.mem.startsWith(u8, trimmed, "zig_flags:")) {
            in_dependencies = false;
            const val_part = std.mem.trim(u8, trimmed["zig_flags:".len..], " \r\t");
            const unquoted = stripQuotes(val_part);
            var flag_tokenizer = std.mem.tokenizeScalar(u8, unquoted, ' ');
            while (flag_tokenizer.next()) |flag| {
                try flags.append(allocator, try allocator.dupe(u8, flag));
            }
            continue;
        }
        
        if (in_dependencies) {
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
                    const name = std.mem.trim(u8, trimmed[0..colon_idx], " \r\t'\"");
                    const path_val = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \r\t'\"");
                    if (name.len > 0 and path_val.len > 0) {
                        try deps.append(allocator, .{
                            .name = try allocator.dupe(u8, name),
                            .path = try allocator.dupe(u8, path_val),
                        });
                    }
                }
            } else if (trimmed.len > 0) {
                in_dependencies = false;
            }
        }
    }
    
    return Frontmatter{ .dependencies = deps, .flags = flags };
}

fn stripQuotes(s: []const u8) []const u8 {
    var result = s;
    if (std.mem.startsWith(u8, result, "\"") and std.mem.endsWith(u8, result, "\"")) {
        result = result[1 .. result.len - 1];
    } else if (std.mem.startsWith(u8, result, "'") and std.mem.endsWith(u8, result, "'")) {
        result = result[1 .. result.len - 1];
    }
    return result;
}

fn runAllZigBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    accumulated_blocks: std.ArrayList(BlockInfo),
    deps: std.ArrayList(Dependency),
    flags: std.ArrayList([]const u8),
    input_file_dir: []const u8,
    keep_temp: bool,
) ![]const u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    const repo_root = try std.fs.path.resolve(allocator, &.{ exe_dir, "../.." });
    defer allocator.free(repo_root);
    const temp_dir_path = try std.fs.path.join(allocator, &.{ repo_root, ".temp" });
    defer allocator.free(temp_dir_path);
    
    // Create the .temp directory if it doesn't exist
    std.Io.Dir.createDirPath(.cwd(), io, temp_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    const temp_file_name = "snippet_full.zig";
    const temp_file_path = try std.fs.path.join(allocator, &.{ temp_dir_path, temp_file_name });
    defer allocator.free(temp_file_path);
    
    // Assemble the code
    var has_main = false;
    for (accumulated_blocks.items) |block| {
        if (std.mem.indexOf(u8, block.code, "fn main") != null) {
            has_main = true;
            break;
        }
    }
    
    var final_code: std.ArrayList(u8) = .empty;
    defer final_code.deinit(allocator);
    
    if (has_main) {
        // Just concatenate all blocks as-is
        for (accumulated_blocks.items) |block| {
            try final_code.appendSlice(allocator, block.code);
            try final_code.appendSlice(allocator, "\n\n");
        }
    } else {
        // Concatenate helper blocks (is_runnable = false) at global scope
        for (accumulated_blocks.items) |block| {
            if (!block.is_runnable) {
                try final_code.appendSlice(allocator, block.code);
                try final_code.appendSlice(allocator, "\n\n");
            }
        }
        
        // Check if init is used
        var uses_init = false;
        for (accumulated_blocks.items) |block| {
            if (block.is_runnable) {
                if (std.mem.indexOf(u8, block.code, "init.") != null) {
                    uses_init = true;
                    break;
                }
            }
        }
        
        // Wrap execution blocks (is_runnable = true) sequentially inside main
        try final_code.appendSlice(allocator, "pub fn main(init: std.process.Init) !void {\n");
        if (!uses_init) {
            try final_code.appendSlice(allocator, "    _ = init;\n");
        }
        for (accumulated_blocks.items) |block| {
            if (block.is_runnable) {
                // Insert section delimiter print
                try final_code.appendSlice(allocator, "    std.debug.print(\"<<<SECTION_");
                const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{block.block_index});
                defer allocator.free(idx_str);
                try final_code.appendSlice(allocator, idx_str);
                try final_code.appendSlice(allocator, ">>>\\n\", .{});\n");
                
                // Insert block code
                try final_code.appendSlice(allocator, block.code);
                try final_code.appendSlice(allocator, "\n");
            }
        }
        try final_code.appendSlice(allocator, "}\n");
    }
    
    const final_code_str = try final_code.toOwnedSlice(allocator);
    defer allocator.free(final_code_str);
    
    const file = try std.Io.Dir.createFileAbsolute(io, temp_file_path, .{});
    try file.writePositionalAll(io, final_code_str, 0);
    file.close(io);
    
    defer {
        if (!keep_temp) {
            std.Io.Dir.deleteFileAbsolute(io, temp_file_path) catch {};
        }
    }
    
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    
    try argv.append(allocator, "zig");
    try argv.append(allocator, "run");
    
    for (deps.items) |dep| {
        try argv.append(allocator, "--dep");
        try argv.append(allocator, dep.name);
    }
    
    const root_mod_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{temp_file_path});
    defer allocator.free(root_mod_arg);
    try argv.append(allocator, root_mod_arg);
    
    for (deps.items) |dep| {
        const abs_dep_path = if (std.mem.startsWith(u8, dep.path, "http") or std.mem.startsWith(u8, dep.path, "git@")) blk: {
            const cache_dir = try std.fs.path.join(allocator, &.{ temp_dir_path, "cache", dep.name });
            var dir_exists = false;
            if (std.Io.Dir.openFileAbsolute(io, cache_dir, .{})) |f| {
                f.close(io);
                dir_exists = true;
            } else |err| switch (err) {
                error.IsDir, error.AccessDenied => dir_exists = true,
                else => {},
            }
            
            if (!dir_exists) {
                std.debug.print("Cloning remote dependency {s} from {s}...\n", .{ dep.name, dep.path });
                const clone_argv = &[_][]const u8{ "git", "clone", "--depth", "1", dep.path, cache_dir };
                const clone_res = try std.process.run(allocator, io, .{
                    .argv = clone_argv,
                    .environ_map = environ_map,
                });
                const clone_exited_normally = switch (clone_res.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                if (!clone_exited_normally) {
                    return try std.fmt.allocPrint(allocator, "Failed to clone remote dependency {s}: {s}\n", .{ dep.name, clone_res.stderr });
                }
            }
            break :blk cache_dir;
        } else try resolvePath(allocator, input_file_dir, dep.path);
        
        defer allocator.free(abs_dep_path);
        
        const mod_root_file = try findModuleRoot(allocator, io, abs_dep_path);
        defer allocator.free(mod_root_file);
        
        const dep_mod_arg = try std.fmt.allocPrint(allocator, "-M{s}={s}", .{ dep.name, mod_root_file });
        try argv.append(allocator, dep_mod_arg);
    }
    
    for (flags.items) |flag| {
        try argv.append(allocator, flag);
    }
    
    // Auto-detect host macOS SDK to resolve frameworks like Accelerate in sandboxed Nix environments
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        if (findHostSdkPath(io)) |sdk_path| {
            try environ_map.put("SDKROOT", sdk_path);
        }
    }

    const run_result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = input_file_dir },
        .environ_map = environ_map,
    }) catch |err| {
        return try std.fmt.allocPrint(allocator, "Failed to execute zig run: {}\n", .{err});
    };
    
    const exited_normally = switch (run_result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    
    const ran_successfully = exited_normally or 
                             (std.mem.indexOf(u8, run_result.stdout, "<<<SECTION_") != null) or 
                             (std.mem.indexOf(u8, run_result.stderr, "<<<SECTION_") != null);
    
    if (!ran_successfully) {
        var err_buf: std.ArrayList(u8) = .empty;
        try err_buf.appendSlice(allocator, "Compilation Error:\n");
        if (run_result.stderr.len > 0) {
            try err_buf.appendSlice(allocator, run_result.stderr);
        } else if (run_result.stdout.len > 0) {
            try err_buf.appendSlice(allocator, run_result.stdout);
        } else {
            try err_buf.appendSlice(allocator, "Failed to compile/execute the program.\n");
        }
        return try err_buf.toOwnedSlice(allocator);
    }
    
    var out_buf: std.ArrayList(u8) = .empty;
    if (run_result.stdout.len > 0) {
        try out_buf.appendSlice(allocator, run_result.stdout);
    }
    if (run_result.stderr.len > 0) {
        try out_buf.appendSlice(allocator, run_result.stderr);
    }
    return try out_buf.toOwnedSlice(allocator);
}

fn extractSectionOutput(allocator: std.mem.Allocator, full_output: []const u8, block_index: usize) ![]const u8 {
    if (std.mem.startsWith(u8, full_output, "Compilation Error:")) {
        return try allocator.dupe(u8, full_output);
    }
    
    const start_marker = try std.fmt.allocPrint(allocator, "<<<SECTION_{d}>>>\n", .{block_index});
    defer allocator.free(start_marker);
    
    const start_marker_no_nl = try std.fmt.allocPrint(allocator, "<<<SECTION_{d}>>>", .{block_index});
    defer allocator.free(start_marker_no_nl);
    
    var start_pos = std.mem.indexOf(u8, full_output, start_marker);
    var marker_len = start_marker.len;
    if (start_pos == null) {
        start_pos = std.mem.indexOf(u8, full_output, start_marker_no_nl);
        marker_len = start_marker_no_nl.len;
    }
    
    if (start_pos) |pos| {
        const content_start = pos + marker_len;
        
        var end_pos = full_output.len;
        var next_idx = block_index + 1;
        while (true) {
            const next_marker = try std.fmt.allocPrint(allocator, "<<<SECTION_{d}>>>", .{next_idx});
            defer allocator.free(next_marker);
            if (std.mem.indexOf(u8, full_output[content_start..], next_marker)) |offset| {
                end_pos = content_start + offset;
                break;
            }
            if (next_idx > block_index + 20) break;
            next_idx += 1;
        }
        return try allocator.dupe(u8, full_output[content_start..end_pos]);
    }
    
    return try allocator.dupe(u8, "[Execution skipped/halted due to upstream error]");
}

fn findHostSdkPath(io: std.Io) ?[]const u8 {
    const paths = [_][]const u8{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    };
    for (paths) |p| {
        var exists = false;
        if (std.Io.Dir.openFileAbsolute(io, p, .{})) |f| {
            f.close(io);
            exists = true;
        } else |err| switch (err) {
            error.IsDir, error.AccessDenied => exists = true,
            else => {},
        }
        if (exists) return p;
    }
    return null;
}
