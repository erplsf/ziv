const std = @import("std");
const x = @cImport(@cInclude("X11/Xlib.h"));

pub fn main() !void {
    // // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    // std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // // stdout is for the actual output of your application, for example if you
    // // are implementing gzip, then only the compressed bytes should be sent to
    // // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    // try stdout.print("Run `zig build test` to run the tests.\n", .{});

    // try bw.flush(); // don't forget to flush!

    // Open connection to the server
    var dpy = x.XOpenDisplay(null) orelse std.debug.panic("Couldn't open a connection to Xserver, exiting!", .{});

    var blackColor = x.BlackPixel(dpy, x.DefaultScreen(dpy));
    var whiteColor = x.WhitePixel(dpy, x.DefaultScreen(dpy));

    // Create the window
    var w = x.XCreateSimpleWindow(dpy, x.DefaultRootWindow(dpy), 0, 0, 200, 100, 0, blackColor, blackColor);

    // We want to get MapNotify events
    _ = x.XSelectInput(dpy, w, x.StructureNotifyMask);

    // "Map" the window (that is, make it appear on the screen)
    _ = x.XMapWindow(dpy, w);

    // Create a "Graphics Context"
    var gc = x.XCreateGC(dpy, w, 0, null);

    // Tell the GC we draw using the white color
    _ = x.XSetForeground(dpy, gc, whiteColor);

    // Wait for the MapNotify event
    while (true) {
        var e: x.XEvent = undefined;
        _ = x.XNextEvent(dpy, &e);
        if (e.type == x.MapNotify)
            break;
    }

    // Draw the line
    _ = x.XDrawLine(dpy, w, gc, 10, 60, 180, 20);

    // Send the "DrawLine" request to the server
    _ = x.XFlush(dpy);

    // Wait for 10 seconds
    std.time.sleep(10 * 1e9);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
