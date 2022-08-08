const std = @import("std");
const json = std.json;

const logger = std.log.scoped(.main);
pub const log_level = .debug;

fn getHomeDir() []const u8 {
    return std.os.getenv("HOME") orelse "";
}

fn readConfig(config_file_path: []const u8, allocator: std.mem.Allocator) anyerror![]const u8 {
    var config_file: std.fs.File = undefined;
    if (std.fs.openFileAbsolute(config_file_path, std.fs.File.OpenFlags{ .mode = .read_only })) |file| {
        config_file = file;
    } else |err| switch (err) {
        error.FileNotFound => {
            try std.fs.makeDirAbsolute(std.fs.path.dirname(config_file_path).?);
            config_file = try std.fs.createFileAbsolute(config_file_path, std.fs.File.CreateFlags{ .read = true });
        },
        else => {
            logger.err("Could not open {}", .{err});
            return err;
        },
    }
    var file_buf = try config_file.readToEndAlloc(allocator, 0x10000000);
    defer config_file.close();
    return file_buf;
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const home_dir = getHomeDir();
    if (std.mem.eql(u8, home_dir, "")) {
        logger.info("Could not get home directory from $HOME environemt variable", .{});
        std.os.exit(1);
    }
    var config_file_path = try std.fs.path.join(allocator, &.{ home_dir, ".ug", "cmd.json" });

    var arg_it = try std.process.ArgIterator.initWithAllocator(allocator);
    if (!arg_it.skip()) @panic("Could not find self argument");

    var cli_command = arg_it.next() orelse {
        logger.info("Could not find command", .{});
        std.os.exit(1);
    };
    if (std.mem.eql(u8, cli_command, "set")) {
        var name: []const u8 = "";
        var upgrade_command: []const u8 = "";

        while (arg_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--name")) {
                name = arg_it.next() orelse "";
            }
            if (std.mem.eql(u8, arg, "--command")) {
                upgrade_command = arg_it.next() orelse "";
            }
        }

        if (std.mem.eql(u8, name, "")) {
            logger.info("Set `--name` flag", .{});
            std.os.exit(1);
        }
        if (std.mem.eql(u8, upgrade_command, "")) {
            logger.info("Set `--command` flag", .{});
            std.os.exit(1);
        }

        const file_buf = try readConfig(config_file_path, allocator);
        var tree: json.ValueTree = undefined;
        if (std.mem.eql(u8, file_buf, "")) {
            var arena_allocator = std.heap.ArenaAllocator.init(allocator);
            tree = json.ValueTree{ .arena = arena_allocator, .root = json.Value{ .Object = json.ObjectMap.init(allocator) } };
        } else {
            var parser = json.Parser.init(allocator, false);
            tree = try parser.parse(file_buf);
        }
        try tree.root.Object.put(name, json.Value{ .String = upgrade_command });
        var file = try std.fs.openFileAbsolute(config_file_path, std.fs.File.OpenFlags{ .mode = .write_only });
        defer file.close();
        try tree.root.jsonStringify(json.StringifyOptions{}, file.writer());
    } else if (std.mem.eql(u8, cli_command, "unset")) {
        var name: []const u8 = "";

        while (arg_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--name")) {
                name = arg_it.next() orelse "";
            }
        }

        if (std.mem.eql(u8, name, "")) {
            logger.info("Set `--name` flag", .{});
            std.os.exit(1);
        }

        const file_buf = try readConfig(config_file_path, allocator);
        var parser = json.Parser.init(allocator, false);
        var tree = try parser.parse(file_buf);
        if (!tree.root.Object.orderedRemove(name)) {
            logger.info("{s} is not set in config", .{name});
            std.os.exit(1);
        }
        var file = try std.fs.createFileAbsolute(config_file_path, .{});
        defer file.close();
        try tree.root.jsonStringify(json.StringifyOptions{}, file.writer());
    } else if (std.mem.eql(u8, cli_command, "list")) {
        const file_buf = try readConfig(config_file_path, allocator);
        var parser = json.Parser.init(allocator, false);
        var tree = try parser.parse(file_buf);
        var config = tree.root.Object;
        var buf: [1000]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        for (config.keys()) |key| {
            try std.fmt.format(fbs.writer(), "{s} = {s}\n", .{ key, config.get(key).?.String });
        }
        std.debug.print("{s}", .{fbs.getWritten()});
    } else {
        const file_buf = try readConfig(config_file_path, allocator);
        var parser = json.Parser.init(allocator, false);
        var tree = try parser.parse(file_buf);
        var upgrade_command = tree.root.Object.get(cli_command).?.String;
        var array = std.ArrayList([]const u8).init(allocator);
        try array.append("bash");
        try array.append("-c");
        try array.append(upgrade_command);

        var child_process = std.ChildProcess.init(array.items, allocator);
        var term = try child_process.spawnAndWait();
        std.os.exit(term.Exited);
    }
}
