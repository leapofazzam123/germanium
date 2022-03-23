const std = @import("std");
const network = @import("zig-network");
const uri = @import("zig-uri");
const ssl = @import("zig-bearssl");
const gemini = @import("./gemini.zig");
const http = @import("apple_pie");
const fs = http.FileServer;
const router = http.router;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try fs.init(allocator, .{ .dir_path = "src/static", .base_path = "files" });
    defer fs.deinit();

    const builder = router.Builder(void);

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 5000),
        {},
        comptime router.Router(void, &.{
            builder.get("/:url", null, index),
            builder.get("/static/*", null, fs.serve),
        }),
    );
}

fn index(_: void, resp: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    _ = req;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var trust_anchors = ssl.TrustAnchorCollection.init(allocator);
    defer trust_anchors.deinit();

    var file = try std.fs.cwd().openFile("cert.pem", .{ .read = true, .write = false });
    defer file.close();

    const pem_text = try file.reader().readAllAlloc(allocator, 1 << 20); // 1 MB
    defer allocator.free(pem_text);

    try trust_anchors.appendFromPEM(pem_text);

    // TODO:
    // - "gemini://heavysquare.com/" does not send an end-of-stream?!
    // - ""gemini://typed-hole.org/topkek" does not send an end-of-stream?!

    var known_certificate_verification: ?gemini.RequestVerification = null;
    defer if (known_certificate_verification) |v| {
        // we know that it's always a public_key for TOFU
        v.public_key.deinit();
    };

    const request_options = gemini.RequestOptions{
        .memory_limit = 268435456, // 256 MB
        .verification = known_certificate_verification orelse gemini.RequestVerification{
            .trust_anchor = trust_anchors,
        },
    };

    const url = @ptrCast(
        *const []const u8,
        @alignCast(
            @alignOf(*const []const u8),
            captures,
        ),
    );

    _ = url;

    var response = gemini.requestRaw(allocator, "gemini://gemini.circumlunar.space/", request_options) catch |err| switch (err) {
        error.MissingAuthority => {
            try resp.writer().writeAll("The url does not contain a host name!\n");
            //return 1;
        },

        error.UnsupportedScheme => {
            try resp.writer().writeAll("The url scheme is not supported!\n");
            //return 1;
        },

        error.CouldNotConnect => {
            try resp.writer().writeAll("Failed to connect to the server. Is the address correct and the server reachable?\n");
            //return 1;
        },

        error.BadServerName => {
            try resp.writer().writeAll("The server certificate is not valid for the given host name!\n");
            //return 1;
        },

        //else => return err,
    };
    defer response.free(allocator);

    switch (response.content) {
        .success => |body| {
            // what are we doing with the mime type here?
            try resp.writer().print("MIME: {s}\n", .{body.mime});

            if (!std.mem.startsWith(u8, body.mime, "text/")) {
                try resp.writer().print("Will not write data of type {s} to stdout unless --force-binary-on-stdout is used.\n", .{
                    body.mime,
                });
            }
            try resp.writer().writeAll(body.data);
        },
        .untrustedCertificate => {
            try resp.writer().writeAll("Server is not trusted. Use --accept-host to add the server to your trust store!\n");
        },
        .badSignature => {
            try resp.writer().print(
                "Signature mismatch! The host  could not be verified!\n",
                .{},
            );
        },
        else => try resp.writer().print("unimplemented response type: {s}\n", .{response}),
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
