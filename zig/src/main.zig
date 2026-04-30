// browser-provisioning / Zig — vers_sdk + vers CLI + puppeteer-core (inside VM)
// VERS_API_KEY must be set. `vers` CLI must be on PATH.

const std = @import("std");
const vers = @import("vers_sdk");

var active_vms: [16][36]u8 = undefined;
var active_vm_count: usize = 0;

fn addVm(id: []const u8) void {
    if (id.len == 36 and active_vm_count < 16) {
        @memcpy(&active_vms[active_vm_count], id);
        active_vm_count += 1;
    }
}

fn removeVm(id: []const u8) void {
    for (0..active_vm_count) |i| {
        if (std.mem.eql(u8, &active_vms[i], id)) {
            if (i < active_vm_count - 1) {
                active_vms[i] = active_vms[active_vm_count - 1];
            }
            active_vm_count -= 1;
            return;
        }
    }
}

fn cleanup(client: *const vers.Client) void {
    for (0..active_vm_count) |i| {
        log("[cleanup] Deleting VM {s}...\n", .{active_vms[i]});
        var resp = client.delete_vm(&active_vms[i], null, null) catch continue;
        resp.deinit();
    }
    active_vm_count = 0;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout.writeAll(msg) catch {};
}

fn getJsonField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const val = parsed.value.object.get(field) orelse return error.FieldNotFound;
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.FieldNotFound,
    };
}

fn getNestedVmId(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const vms = parsed.value.object.get("vms") orelse return error.FieldNotFound;
    const arr = vms.array;
    if (arr.items.len == 0) return error.FieldNotFound;
    const vm_id = arr.items[0].object.get("vm_id") orelse return error.FieldNotFound;
    return switch (vm_id) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.FieldNotFound,
    };
}

fn versExec(allocator: std.mem.Allocator, vm_id: []const u8, script: []const u8, timeout: u32) ![]const u8 {
    const cmd = try std.fmt.allocPrint(allocator, "cat <<'EOFSCRIPT' | vers exec -i -t {d} {s} bash\n{s}\nEOFSCRIPT", .{ timeout, vm_id, script });
    defer allocator.free(cmd);

    var child = std.process.Child.init(&.{ "/bin/bash", "-c", cmd }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var out: std.ArrayList(u8) = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    _ = try child.wait();
    return try out.toOwnedSlice(allocator);
}

fn versWait(allocator: std.mem.Allocator, vm_id: []const u8) !void {
    for (0..40) |_| {
        const out = versExec(allocator, vm_id, "echo ready", 10) catch {
            std.Thread.sleep(3 * std.time.ns_per_s);
            continue;
        };
        defer allocator.free(out);
        if (std.mem.indexOf(u8, out, "ready") != null) return;
        std.Thread.sleep(3 * std.time.ns_per_s);
    }
    return error.VmNotReady;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 1024 * 1024);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var client = vers.Client.init(a, .{});

    log("=== [Zig] Building golden image ===\n\n", .{});

    // 1. Create root VM
    log("[1/4] Creating root VM...\n", .{});
    var root_resp = try client.create_new_root_vm(
        \\{"vm_config":{"vcpu_count":2,"mem_size_mib":4096,"fs_size_mib":8192,"kernel_name":"default.bin","image_name":"default"}}
    , true, null);
    defer root_resp.deinit();
    const build_vm = try getJsonField(a, root_resp.body, "vm_id");
    defer a.free(build_vm);
    addVm(build_vm);
    log("  VM: {s}\n", .{build_vm});

    // 2. Wait for VM
    log("[2/4] Waiting for VM...\n", .{});
    versWait(a, build_vm) catch {
        cleanup(&client);
        std.process.exit(1);
    };

    // 3. Install Chromium
    log("[3/4] Installing Chromium...\n", .{});
    const install = try readFile(a, "../install.sh");
    defer a.free(install);
    const iout = versExec(a, build_vm, install, 600) catch {
        cleanup(&client);
        std.process.exit(1);
    };
    a.free(iout);

    // 4. Commit
    log("[4/4] Committing...\n", .{});
    var commit_resp = try client.commit_vm(build_vm, "{}", null, null, null);
    defer commit_resp.deinit();
    const commit_id = try getJsonField(a, commit_resp.body, "commit_id");
    defer a.free(commit_id);
    log("  Commit: {s}\n", .{commit_id});

    var del_resp = client.delete_vm(build_vm, null, null) catch null;
    if (del_resp) |*r| r.deinit();
    removeVm(build_vm);
    log("  Build VM deleted\n\n", .{});

    // Branch from commit & scrape
    log("=== Branching from commit & scraping ===\n\n", .{});

    log("[1/3] Branching...\n", .{});
    var branch_resp = try client.branch_by_commit(commit_id, "{}", null, null);
    defer branch_resp.deinit();
    const vm_id = try getNestedVmId(a, branch_resp.body);
    defer a.free(vm_id);
    addVm(vm_id);
    log("  VM: {s}\n", .{vm_id});

    log("[2/3] Waiting for VM...\n", .{});
    versWait(a, vm_id) catch {
        cleanup(&client);
        std.process.exit(1);
    };

    log("[3/3] Scraping...\n\n", .{});
    const scrape = try readFile(a, "../scrape.sh");
    defer a.free(scrape);
    const sout = versExec(a, vm_id, scrape, 120) catch {
        cleanup(&client);
        std.process.exit(1);
    };
    defer a.free(sout);

    // Print JSON output
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, sout, &std.ascii.whitespace), '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '{') {
            log("{s}\n", .{line});
            break;
        }
    }

    var vdel_resp = client.delete_vm(vm_id, null, null) catch null;
    if (vdel_resp) |*r| r.deinit();
    removeVm(vm_id);
    log("\nVM {s} deleted. Done.\n", .{vm_id});
}
