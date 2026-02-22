const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const net_security = @import("../root.zig").net_security;

/// HTTP request tool for API interactions.
/// Supports GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS methods with
/// domain allowlisting, SSRF protection, and header redaction.
pub const HttpRequestTool = struct {
    allowed_domains: []const []const u8 = &.{}, // empty = allow all

    pub const tool_name = "http_request";
    pub const tool_description = "Make HTTP requests to external APIs. Supports GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS methods. " ++
        "Security: allowlist-only domains, no local/private hosts, SSRF protection.";
    pub const tool_params =
        \\{"type":"object","properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to request"},"method":{"type":"string","description":"HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS)","default":"GET"},"headers":{"type":"object","description":"Optional HTTP headers as key-value pairs"},"body":{"type":"string","description":"Optional request body"}},"required":["url"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *HttpRequestTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *HttpRequestTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing 'url' parameter");

        const method_str = root.getString(args, "method") orelse "GET";

        // Validate URL scheme
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return ToolResult.fail("Only http:// and https:// URLs are allowed");
        }

        // Block localhost/private IPs (SSRF protection)
        const host = net_security.extractHost(url) orelse
            return ToolResult.fail("Invalid URL: cannot extract host");

        if (net_security.isLocalHost(host)) {
            return ToolResult.fail("Blocked local/private host");
        }

        // Check domain allowlist
        if (self.allowed_domains.len > 0) {
            if (!net_security.hostMatchesAllowlist(host, self.allowed_domains)) {
                return ToolResult.fail("Host is not in http_request.allowed_domains");
            }
        }

        // Validate method (curl receives the method string; we still gate here
        // so we return a consistent error before any subprocess is spawned).
        if (validateMethod(method_str) == null) {
            const msg = try std.fmt.allocPrint(allocator, "Unsupported HTTP method: {s}", .{method_str});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Validate URL structure for an early "Invalid URL format" error.
        const uri = std.Uri.parse(url) catch return ToolResult.fail("Invalid URL format");
        _ = uri; // validation only; curl accepts the raw URL string directly

        // Parse custom headers from ObjectMap
        const headers_val = root.getValue(args, "headers");
        var header_list: std.ArrayList([2][]const u8) = .{};
        errdefer {
            for (header_list.items) |h| {
                allocator.free(h[0]);
                allocator.free(h[1]);
            }
            header_list.deinit(allocator);
        }
        if (headers_val) |hv| {
            if (hv == .object) {
                var it = hv.object.iterator();
                while (it.next()) |entry| {
                    const val_str = switch (entry.value_ptr.*) {
                        .string => |s| s,
                        else => continue,
                    };
                    try header_list.append(allocator, .{
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try allocator.dupe(u8, val_str),
                    });
                }
            }
        }
        const custom_headers = header_list.items;
        defer {
            for (custom_headers) |h| {
                allocator.free(h[0]);
                allocator.free(h[1]);
            }
            header_list.deinit(allocator);
        }

        // Execute request via curl subprocess.
        // Zig 0.15 std.http.Client has TLS reliability issues on Alpine musl
        // (error.EndOfStream on HTTPS). curl is installed in the runtime image
        // and uses the system CA bundle (ca-certificates + update-ca-certificates).
        const body: ?[]const u8 = root.getString(args, "body");

        // Sentinel appended by curl -w; allows us to slice status code off the
        // end of the combined stdout result without a temp file.
        const status_sentinel = "\n<<<HTTP_SC>>>";

        // Build "Key: Value" header strings for -H args; freed after subprocess.
        var header_strs: std.ArrayList([]u8) = .{};
        defer {
            for (header_strs.items) |s| allocator.free(s);
            header_strs.deinit(allocator);
        }
        for (custom_headers) |h| {
            const hs = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h[0], h[1] });
            try header_strs.append(allocator, hs);
        }

        // Argv: curl -s -w SENTINEL -X METHOD [-H key:val]... [--data-raw body] URL
        const max_argc: usize = 8 + (header_strs.items.len * 2) + 2 + 1;
        const argv = try allocator.alloc([]const u8, max_argc);
        defer allocator.free(argv);
        var argc: usize = 0;

        argv[argc] = "curl";     argc += 1;
        argv[argc] = "-s";       argc += 1;
        argv[argc] = "-w";       argc += 1;
        argv[argc] = status_sentinel ++ "%{http_code}"; argc += 1;
        argv[argc] = "-X";       argc += 1;
        argv[argc] = method_str; argc += 1;

        for (header_strs.items) |hs| {
            argv[argc] = "-H"; argc += 1;
            argv[argc] = hs;   argc += 1;
        }

        if (body) |b| {
            argv[argc] = "--data-raw"; argc += 1;
            argv[argc] = b;            argc += 1;
        }

        argv[argc] = url; argc += 1;

        var child = std.process.Child.init(argv[0..argc], allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to launch curl: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        const raw_output = child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024) catch {
            _ = child.wait() catch {};
            return ToolResult.fail("Failed to read curl stdout");
        };
        defer allocator.free(raw_output);

        // Always heap-allocated so we can unconditionally free it below.
        const stderr_output = child.stderr.?.readToEndAlloc(allocator, 64 * 1024) catch
            try allocator.dupe(u8, "");
        defer allocator.free(stderr_output);

        const term = child.wait() catch return ToolResult.fail("curl process wait failed");
        switch (term) {
            .Exited => |code| if (code != 0) {
                const msg = if (stderr_output.len > 0)
                    try std.fmt.allocPrint(allocator, "curl failed (exit {d}): {s}", .{ code, stderr_output })
                else
                    try std.fmt.allocPrint(allocator, "curl failed with exit code {d}", .{code});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
            else => return ToolResult.fail("curl process terminated abnormally"),
        }

        // Parse HTTP status code from end of output.
        // Output format: <body>\n<<<HTTP_SC>>><three-digit code>
        const sentinel_pos = std.mem.lastIndexOf(u8, raw_output, status_sentinel) orelse
            return ToolResult.fail("Could not parse HTTP status (sentinel missing from curl output)");

        const response_body = raw_output[0..sentinel_pos];
        const status_str = std.mem.trim(u8, raw_output[sentinel_pos + status_sentinel.len ..], " \t\r\n");
        const status_code = std.fmt.parseInt(u16, status_str, 10) catch
            return ToolResult.fail("Could not parse HTTP status code from curl output");

        const success = status_code >= 200 and status_code < 300;

        // Build redacted headers display for custom request headers
        const redacted = redactHeadersForDisplay(allocator, custom_headers) catch "";
        defer if (redacted.len > 0) allocator.free(redacted);

        const output = if (redacted.len > 0)
            try std.fmt.allocPrint(
                allocator,
                "Status: {d}\nRequest Headers: {s}\n\nResponse Body:\n{s}",
                .{ status_code, redacted, response_body },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "Status: {d}\n\nResponse Body:\n{s}",
                .{ status_code, response_body },
            );

        if (success) {
            return ToolResult{ .success = true, .output = output };
        } else {
            const err_msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{status_code});
            return ToolResult{ .success = false, .output = output, .error_msg = err_msg };
        }
    }
};

fn validateMethod(method: []const u8) ?std.http.Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return .OPTIONS;
    return null;
}

/// Parse headers from a JSON object string: {"Key": "Value", ...}
/// Returns array of [2][]const u8 pairs. Caller owns memory.
fn parseHeaders(allocator: std.mem.Allocator, headers_json: ?[]const u8) ![]const [2][]const u8 {
    const json = headers_json orelse return &.{};
    if (json.len < 2) return &.{};

    var list: std.ArrayList([2][]const u8) = .{};
    errdefer {
        for (list.items) |h| {
            allocator.free(h[0]);
            allocator.free(h[1]);
        }
        list.deinit(allocator);
    }

    // Simple JSON object parser: find "key": "value" pairs
    var pos: usize = 0;
    while (pos < json.len) {
        // Find next key (quoted string)
        const key_start = std.mem.indexOfScalarPos(u8, json, pos, '"') orelse break;
        const key_end = std.mem.indexOfScalarPos(u8, json, key_start + 1, '"') orelse break;
        const key = json[key_start + 1 .. key_end];

        // Skip to colon and value
        pos = key_end + 1;
        const colon = std.mem.indexOfScalarPos(u8, json, pos, ':') orelse break;
        pos = colon + 1;

        // Skip whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}

        if (pos >= json.len or json[pos] != '"') {
            pos += 1;
            continue;
        }
        const val_start = pos;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start + 1, '"') orelse break;
        const value = json[val_start + 1 .. val_end];
        pos = val_end + 1;

        try list.append(allocator, .{
            try allocator.dupe(u8, key),
            try allocator.dupe(u8, value),
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Redact sensitive headers for display output.
/// Headers with names containing authorization, api-key, apikey, token, secret,
/// or password (case-insensitive) get their values replaced with "***REDACTED***".
fn redactHeadersForDisplay(allocator: std.mem.Allocator, headers: []const [2][]const u8) ![]const u8 {
    if (headers.len == 0) return "";

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    for (headers, 0..) |h, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, h[0]);
        try buf.appendSlice(allocator, ": ");
        if (isSensitiveHeader(h[0])) {
            try buf.appendSlice(allocator, "***REDACTED***");
        } else {
            try buf.appendSlice(allocator, h[1]);
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Check if a header name is sensitive (case-insensitive substring check).
fn isSensitiveHeader(name: []const u8) bool {
    // Convert to lowercase for comparison
    var lower_buf: [256]u8 = undefined;
    if (name.len > lower_buf.len) return false;
    const lower = lower_buf[0..name.len];
    for (name, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    if (std.mem.indexOf(u8, lower, "authorization") != null) return true;
    if (std.mem.indexOf(u8, lower, "api-key") != null) return true;
    if (std.mem.indexOf(u8, lower, "apikey") != null) return true;
    if (std.mem.indexOf(u8, lower, "token") != null) return true;
    if (std.mem.indexOf(u8, lower, "secret") != null) return true;
    if (std.mem.indexOf(u8, lower, "password") != null) return true;
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

test "http_request tool name" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    try std.testing.expectEqualStrings("http_request", t.name());
}

test "http_request tool description not empty" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    try std.testing.expect(t.description().len > 0);
}

test "http_request schema has url" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "url") != null);
}

test "http_request schema has headers" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "headers") != null);
}

test "validateMethod accepts valid methods" {
    try std.testing.expect(validateMethod("GET") != null);
    try std.testing.expect(validateMethod("POST") != null);
    try std.testing.expect(validateMethod("PUT") != null);
    try std.testing.expect(validateMethod("DELETE") != null);
    try std.testing.expect(validateMethod("PATCH") != null);
    try std.testing.expect(validateMethod("HEAD") != null);
    try std.testing.expect(validateMethod("OPTIONS") != null);
    try std.testing.expect(validateMethod("get") != null); // case insensitive
}

test "validateMethod rejects invalid" {
    try std.testing.expect(validateMethod("INVALID") == null);
}

// ── redactHeadersForDisplay tests ──────────────────────────

test "redactHeadersForDisplay redacts Authorization" {
    const headers = [_][2][]const u8{
        .{ "Authorization", "Bearer secret-token" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "***REDACTED***") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "secret-token") == null);
}

test "redactHeadersForDisplay preserves Content-Type" {
    const headers = [_][2][]const u8{
        .{ "Content-Type", "application/json" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "REDACTED") == null);
}

test "redactHeadersForDisplay redacts api-key and token" {
    const headers = [_][2][]const u8{
        .{ "X-API-Key", "my-key" },
        .{ "X-Secret-Token", "tok-123" },
    };
    const result = try redactHeadersForDisplay(std.testing.allocator, &headers);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "my-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tok-123") == null);
}

test "redactHeadersForDisplay empty returns empty" {
    const result = try redactHeadersForDisplay(std.testing.allocator, &.{});
    try std.testing.expectEqualStrings("", result);
}

test "isSensitiveHeader checks" {
    try std.testing.expect(isSensitiveHeader("Authorization"));
    try std.testing.expect(isSensitiveHeader("X-API-Key"));
    try std.testing.expect(isSensitiveHeader("X-Secret-Token"));
    try std.testing.expect(isSensitiveHeader("password-header"));
    try std.testing.expect(!isSensitiveHeader("Content-Type"));
    try std.testing.expect(!isSensitiveHeader("Accept"));
}

// ── execute-level tests ──────────────────────────────────────

test "execute rejects missing url parameter" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "url") != null);
}

test "execute rejects non-http scheme" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"ftp://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "http") != null);
}

test "execute rejects localhost SSRF" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"http://127.0.0.1:8080/admin\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "local") != null);
}

test "execute rejects localhost SSRF with URL userinfo" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"http://user:pass@127.0.0.1:8080/admin\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "local") != null);
}

test "execute rejects localhost SSRF with unbracketed ipv6 authority" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"http://::1:8080/admin\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "local") != null);
}

test "execute rejects private IP SSRF" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"http://192.168.1.1/admin\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "execute rejects 10.x private range" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"http://10.0.0.1/secret\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "execute rejects unsupported method" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"https://example.com\", \"method\": \"INVALID\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsupported") != null);
}

test "execute rejects invalid URL format" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"http://\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "execute rejects non-allowlisted domain" {
    const domains = [_][]const u8{"example.com"};
    var ht = HttpRequestTool{ .allowed_domains = &domains };
    const t = ht.tool();
    const parsed = try root.parseTestArgs("{\"url\": \"https://evil.com/path\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "allowed_domains") != null);
}

test "http_request parameters JSON is valid" {
    var ht = HttpRequestTool{};
    const t = ht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(schema[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, schema, "method") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "body") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "headers") != null);
}

test "validateMethod case insensitive" {
    try std.testing.expect(validateMethod("get") != null);
    try std.testing.expect(validateMethod("Post") != null);
    try std.testing.expect(validateMethod("pUt") != null);
    try std.testing.expect(validateMethod("delete") != null);
    try std.testing.expect(validateMethod("patch") != null);
    try std.testing.expect(validateMethod("head") != null);
    try std.testing.expect(validateMethod("options") != null);
}

test "validateMethod rejects empty string" {
    try std.testing.expect(validateMethod("") == null);
}

test "validateMethod rejects CONNECT TRACE" {
    try std.testing.expect(validateMethod("CONNECT") == null);
    try std.testing.expect(validateMethod("TRACE") == null);
}

// ── parseHeaders tests ──────────────────────────────────────

test "parseHeaders basic" {
    const headers = try parseHeaders(std.testing.allocator, "{\"Content-Type\": \"application/json\"}");
    defer {
        for (headers) |h| {
            std.testing.allocator.free(h[0]);
            std.testing.allocator.free(h[1]);
        }
        std.testing.allocator.free(headers);
    }
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("Content-Type", headers[0][0]);
    try std.testing.expectEqualStrings("application/json", headers[0][1]);
}

test "parseHeaders null returns empty" {
    const headers = try parseHeaders(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}
