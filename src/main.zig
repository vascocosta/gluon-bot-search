const std = @import("std");
const zeit = @import("zeit");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const ArrayList = std.ArrayList;
const WordList = [MAX_SEARCH_WORDS][]const u8;

const EVENTS_FILE = "/home/gluon/events.csv";
const MAX_EVENTS = 5;
const MAX_SEARCH_WORDS = 4;
const MAX_FILE_SIZE = 500_000;

const Event = struct {
    category: []const u8,
    name: []const u8,
    description: []const u8,
    time: zeit.Time,
    channel: []const u8,
    tags: []const u8,
    notify: bool,
};

fn toLower(allocator: Allocator, input: []const u8) ![]u8 {
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

fn futureEvent(event: *const Event) !bool {
    const now_instant = try zeit.instant(.{});
    const event_instant = event.time.instant();

    return event_instant.timestamp > now_instant.timestamp;
}

fn search(allocator: Allocator, file_size: u64, search_words: WordList, file: *const File) !void {
    const stdout = std.io.getStdOut().writer();

    const buf = try allocator.alloc(u8, std.math.clamp(file_size, 0, MAX_FILE_SIZE));
    _ = file.readAll(buf) catch {
        std.debug.print("Error reading file: {s}\n", .{EVENTS_FILE});

        return;
    };

    var events = ArrayList(Event).init(allocator);
    defer events.deinit();

    var lines = std.mem.splitSequence(u8, buf, "\n");

    while (lines.next()) |line| {
        var fields = std.mem.splitSequence(u8, line, ",");
        const event = Event{
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

        if (try futureEvent(&event)) {
            try events.append(event);
        }
    }

    std.mem.sort(Event, events.items[0..], {}, compareEventTime);

    var event_count: u8 = 0;
    for (events.items) |event| {
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
            try stdout.print("{d:0>2}/{d:0>2}/{d} {d:0>2}:{d:0>2} UTC | {s} | {s} | {s}\n", .{ event.time.day, @intFromEnum(event.time.month), event.time.year, event.time.hour, event.time.minute, event.category, event.name, event.description });
        }
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const file = std.fs.openFileAbsolute(EVENTS_FILE, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => {
                try stdout.print("No access to file: {s}\n", .{EVENTS_FILE});
            },
            error.FileNotFound => {
                try stdout.print("File not found: {s}\n", .{EVENTS_FILE});
            },
            else => {
                try stdout.print("Error opening file: {s}\n", .{EVENTS_FILE});
            },
        }

        return;
    };
    defer file.close();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    if (args.skip() and !args.skip()) {
        try stdout.print("Channel must be passed as the first argument.\n", .{});

        return;
    }

    var search_words: WordList = .{ "", "", "", "" };
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

    try search(allocator, file_size, search_words, &file);
}
