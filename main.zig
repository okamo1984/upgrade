const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const logger = std.log.scoped(.main);
pub const log_level = .debug;

fn getHomeDir() []const u8 {
    return std.os.getenv("HOME") orelse "";
}

const Config = struct {
    allocator: Allocator,
    tree: json.ValueTree,
    file_path: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, tree: json.ValueTree, file_path: []const u8) Config {
        return Config{
            .allocator = allocator,
            .tree = tree,
            .file_path = file_path,
        };
    }

    pub fn upsert(self: *Self, name: []const u8, command: []const u8) !void {
        try self.tree.root.Object.put(name, json.Value{ .String = command });
        const file = try std.fs.createFileAbsolute(self.file_path, .{});
        try self.tree.root.jsonStringify(json.StringifyOptions{}, file.writer());
        file.close();
    }

    pub fn remove(self: *Self, name: []const u8) !void {
        if (!self.tree.root.Object.orderedRemove(name)) {
            logger.info("{s} is not set in config", .{name});
            std.os.exit(1);
        }
        var file = try std.fs.createFileAbsolute(self.file_path, .{});
        try self.tree.root.jsonStringify(json.StringifyOptions{ .whitespace = .{} }, file.writer());
        file.close();
    }

    pub fn printAll(self: Self) !void {
        const config = self.tree.root.Object;
        var array = std.ArrayList([]u8).init(self.allocator);
        for (config.keys()) |key| {
            try array.append(try std.fmt.allocPrint(self.allocator, "{s} = {s}", .{ key, config.get(key).?.String }));
        }
        const s = try std.mem.join(self.allocator, "\n", array.items);
        std.debug.print("{s}", .{s});
    }

    pub fn runCmd(self: Self, command: []const u8) !u8 {
        const upgrade_command = self.tree.root.Object.get(command).?.String;
        var array = std.ArrayList([]const u8).init(self.allocator);
        try array.append("bash");
        try array.append("-c");
        try array.append(upgrade_command);

        var child_process = std.ChildProcess.init(array.items, self.allocator);
        var term = try child_process.spawnAndWait();
        return term.Exited;
    }
};

pub fn parseConfig(config_file_path: []const u8, allocator: Allocator) !Config {
    var config_file: ?std.fs.File = null;
    defer if (config_file) |file| file.close();

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
    const file_buf = try config_file.?.readToEndAlloc(allocator, 0x10000000);
    if (std.mem.eql(u8, file_buf, "") or std.mem.eql(u8, file_buf, "{}")) {
        var tree = json.ValueTree{ .arena = std.heap.ArenaAllocator.init(allocator), .root = json.Value{ .Object = json.ObjectMap.init(allocator) } };
        return Config.init(allocator, tree, config_file_path);
    }

    var parser = json.Parser.init(allocator, false);
    var tree = try parser.parse(file_buf);

    return Config.init(allocator, tree, config_file_path);
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
    const config_file_path: []const u8 = try std.fs.path.join(allocator, &.{ home_dir, ".ug", "cmd.json" });

    var arg_it = try std.process.ArgIterator.initWithAllocator(allocator);
    if (!arg_it.skip()) @panic("Could not find self argument");

    const cli_command = arg_it.next() orelse {
        logger.info("Could not find command", .{});
        std.os.exit(1);
    };

    var config = try parseConfig(config_file_path, allocator);
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

        try config.upsert(name, upgrade_command);
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

        try config.remove(name);
    } else if (std.mem.eql(u8, cli_command, "list")) {
        try config.printAll();
    } else {
        std.os.exit(try config.runCmd(cli_command));
    }
}
