const std = @import("std");
const zeit = @import("zeit");

const EVENTS_FILE = "/home/gluon/var/irc/bots/Vettel/data/events.csv";
const TIME_ZONES_FILE = "/home/gluon/var/irc/bots/Vettel/data/time_zones.csv";
const MAX_EVENTS = 5;
const MAX_SEARCH_WORDS = 4;
const MAX_FILE_SIZE = 500_000;
const DEFAULT_TIME_ZONE = "Etc/UTC";

const Event = struct {
    category: []const u8,
    name: []const u8,
    description: []const u8,
    time: zeit.Time,
    channel: []const u8,
    tags: []const u8,
    notify: bool,
};

fn toLower(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, input.len);

    for (input, 0..input.len) |c, i| {
        result[i] = std.ascii.toLower(c);
    }

    return result;
}

fn compareEventTime(_: void, lhs: Event, rhs: Event) bool {
    const lhs_instant = lhs.time.instant();
    const rhs_instant = rhs.time.instant();

    return lhs_instant.timestamp < rhs_instant.timestamp;
}

fn timeInTimeZone(allocator: std.mem.Allocator, time: zeit.Time, tz_str: []const u8) !zeit.Time {
    const time_zone = try zeit.loadTimeZone(allocator, std.meta.stringToEnum(zeit.Location, tz_str) orelse .@"Etc/UTC", null);
    const utc_instant = time.instant();
    const time_zone_instant = utc_instant.in(&time_zone);

    return time_zone_instant.time();
}

fn timeZoneName(allocator: std.mem.Allocator, nick: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(TIME_ZONES_FILE, .{});
    const file_metadata = try file.metadata();
    const file_size = file_metadata.size();
    const buf = try allocator.alloc(u8, std.math.clamp(file_size, 0, MAX_FILE_SIZE));
    _ = try file.readAll(buf);

    var lines = std.mem.splitSequence(u8, buf, "\n");

    return while (lines.next()) |line| {
        var fields = std.mem.splitSequence(u8, line, ",");
        const nick_field = try toLower(allocator, fields.next() orelse "NA");
        const time_zone_field = fields.next() orelse DEFAULT_TIME_ZONE;

        if (std.mem.eql(u8, nick_field, try toLower(allocator, nick))) {
            break time_zone_field;
        }
    } else DEFAULT_TIME_ZONE;
}

fn shortTimeZoneName(time_zone_name: []const u8) []const u8 {
    const index = std.mem.indexOfPos(u8, time_zone_name, 0, "/") orelse 0;

    if (index > 0 and time_zone_name.len > index + 1) {
        return time_zone_name[index + 1 ..];
    } else {
        return time_zone_name;
    }
}

fn search(
    allocator: std.mem.Allocator,
    file_size: u64,
    nick: []const u8,
    search_words: [MAX_SEARCH_WORDS][]const u8,
    file: *const std.fs.File,
) !void {
    const stdout = std.io.getStdOut().writer();

    const buf = try allocator.alloc(u8, std.math.clamp(file_size, 0, MAX_FILE_SIZE));
    _ = try file.readAll(buf);

    var events = std.ArrayList(Event).init(allocator);
    defer events.deinit();

    var lines = std.mem.splitSequence(u8, buf, "\n");
    while (lines.next()) |line| {
        var fields = std.mem.splitSequence(u8, line, ",");
        var event = Event{
            .category = fields.next() orelse "NA",
            .name = fields.next() orelse "NA",
            .description = fields.next() orelse "NA",
            .time = try zeit.Time.fromISO8601(blk: {
                const arg = fields.next() orelse "2004-01-01 12:00:00";
                break :blk arg[0..19];
            }),
            .channel = fields.next() orelse "NA",
            .tags = fields.next() orelse "NA",
            .notify = false,
        };

        const now_instant = try zeit.instant(.{});

        if (event.time.after(now_instant.time())) {
            try events.append(event);
        }
    }

    std.mem.sort(Event, events.items[0..], {}, compareEventTime);

    var event_count: u8 = 0;
    for (events.items) |*event| {
        var found: bool = false;
        for (search_words) |word| {
            if (word.len > 0) {
                const word_lower = try toLower(allocator, word);
                if (std.mem.indexOf(u8, try toLower(allocator, event.tags), word_lower)) |_| {
                    found = true;
                    event_count += 1;
                }
            }
        }

        if (found and event_count <= MAX_EVENTS) {
            const time_zone_name = try timeZoneName(allocator, nick);
            event.time = try timeInTimeZone(allocator, event.time, time_zone_name);
            try event.time.strftime(stdout, "%a %d %B %H:%M");
            try stdout.print(
                " ({s}) | {s} | {s} | {s}\n",
                .{
                    //event.time.day,
                    //@intFromEnum(event.time.month),
                    //event.time.year,
                    //event.time.hour,
                    //event.time.minute,
                    shortTimeZoneName(time_zone_name),
                    event.category,
                    event.name,
                    event.description,
                },
            );
        }
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const file = std.fs.openFileAbsolute(EVENTS_FILE, .{}) catch |err| {
        try stdout.print("Could not open file: {}", .{err});
        std.process.exit(1);
    };
    defer file.close();

    var nick: []const u8 = "";
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    if (args.next()) |arg| {
        nick = arg;
    } else {
        try stdout.print("Nick must be passed as the first argument.\n", .{});
        std.process.exit(1);
    }

    var search_words: [MAX_SEARCH_WORDS][]const u8 = .{ "", "", "", "" };
    var i: usize = 0;
    while (i < MAX_SEARCH_WORDS) {
        if (args.next()) |arg| {
            search_words[i] = arg;
            i += 1;
        } else {
            break;
        }
    }

    const file_metadata = try file.metadata();
    const file_size = file_metadata.size();

    search(allocator, file_size, nick, search_words, &file) catch |err| {
        try stdout.print("Error searching events: {}", .{err});
        std.process.exit(1);
    };
}
