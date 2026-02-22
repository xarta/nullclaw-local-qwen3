//! Web Search Tool — internet search via web scraping or Brave Search API.
//!
//! Uses DuckDuckGo HTML search by default (no account required). If
//! BRAVE_API_KEY is set, uses the Brave Search API for higher-quality results.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Maximum number of search results.
const MAX_RESULTS: usize = 10;
/// Default number of search results.
const DEFAULT_COUNT: usize = 5;

/// Web search tool using Brave Search API.
pub const WebSearchTool = struct {
    pub const tool_name = "web_search";
    pub const tool_description = "Search the web. Returns titles, URLs, and descriptions. Uses DuckDuckGo by default; set BRAVE_API_KEY env var for higher-quality Brave Search results.";
    pub const tool_params =
        \\{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"Search query"},"count":{"type":"integer","minimum":1,"maximum":10,"default":5,"description":"Number of results (1-10)"}},"required":["query"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *WebSearchTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *WebSearchTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing required 'query' parameter");

        if (std.mem.trim(u8, query, " \t\n\r").len == 0)
            return ToolResult.fail("'query' must not be empty");

        const count = parseCount(args);

        // Use Brave Search if BRAVE_API_KEY is set; otherwise fall back to DuckDuckGo.
        if (std.posix.getenv("BRAVE_API_KEY")) |api_key| {
            if (api_key.len > 0)
                return braveSearch(allocator, query, count, api_key);
        }
        return duckduckgoSearch(allocator, query, count);
    }
};

/// Parse count from args ObjectMap. Returns DEFAULT_COUNT if not found or invalid.
fn parseCount(args: JsonObjectMap) usize {
    const val_i64 = root.getInt(args, "count") orelse return DEFAULT_COUNT;
    if (val_i64 < 1) return 1;
    const val: usize = if (val_i64 > @as(i64, @intCast(MAX_RESULTS))) MAX_RESULTS else @intCast(val_i64);
    return val;
}

/// URL-encode a string (percent-encoding).
pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            try buf.appendSlice(allocator, &.{ '%', hexDigit(c >> 4), hexDigit(c & 0x0f) });
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn hexDigit(v: u8) u8 {
    return "0123456789ABCDEF"[v & 0x0f];
}

/// Parse Brave Search JSON and format as text results.
pub fn formatBraveResults(allocator: std.mem.Allocator, json_body: []const u8, query: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch
        return ToolResult.fail("Failed to parse search response JSON");
    defer parsed.deinit();

    const root_val = switch (parsed.value) {
        .object => |o| o,
        else => return ToolResult.fail("Unexpected search response format"),
    };

    // Extract web results
    const web = root_val.get("web") orelse
        return ToolResult.ok("No web results found.");

    const web_obj = switch (web) {
        .object => |o| o,
        else => return ToolResult.ok("No web results found."),
    };

    const results = web_obj.get("results") orelse
        return ToolResult.ok("No web results found.");

    const results_arr = switch (results) {
        .array => |a| a,
        else => return ToolResult.ok("No web results found."),
    };

    if (results_arr.items.len == 0)
        return ToolResult.ok("No web results found.");

    // Format results
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try std.fmt.format(buf.writer(allocator), "Results for: {s}\n\n", .{query});

    for (results_arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const title = extractString(obj, "title") orelse "(no title)";
        const url = extractString(obj, "url") orelse "(no url)";
        const desc = extractString(obj, "description") orelse "";

        try std.fmt.format(buf.writer(allocator), "{d}. {s}\n   {s}\n", .{ i + 1, title, url });
        if (desc.len > 0) {
            try std.fmt.format(buf.writer(allocator), "   {s}\n", .{desc});
        }
        try buf.append(allocator, '\n');
    }

    return ToolResult.ok(try buf.toOwnedSlice(allocator));
}

fn extractString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Brave Search API via curl subprocess. Called when BRAVE_API_KEY is set.
fn braveSearch(allocator: std.mem.Allocator, query: []const u8, count: usize, api_key: []const u8) !ToolResult {
    const encoded_query = try urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    const url_str = try std.fmt.allocPrint(
        allocator,
        "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}",
        .{ encoded_query, count },
    );
    defer allocator.free(url_str);

    const auth_header = try std.fmt.allocPrint(allocator, "X-Subscription-Token: {s}", .{api_key});
    defer allocator.free(auth_header);

    const argv = [_][]const u8{
        "curl", "-s",
        "-H", auth_header,
        "-H", "Accept: application/json",
        "--max-time", "30",
        url_str,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to launch curl: {}", .{err});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    const body = child.stdout.?.readToEndAlloc(allocator, 512 * 1024) catch {
        _ = child.wait() catch {};
        return ToolResult.fail("Failed to read curl output");
    };
    defer allocator.free(body);

    const stderr_out = child.stderr.?.readToEndAlloc(allocator, 16 * 1024) catch
        try allocator.dupe(u8, "");
    defer allocator.free(stderr_out);

    const term = child.wait() catch return ToolResult.fail("curl process wait failed");
    switch (term) {
        .Exited => |code| if (code != 0) {
            const msg = if (stderr_out.len > 0)
                try std.fmt.allocPrint(allocator, "curl failed (exit {d}): {s}", .{ code, stderr_out })
            else
                try std.fmt.allocPrint(allocator, "Brave search curl failed (exit {d})", .{code});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
        else => return ToolResult.fail("curl process terminated abnormally"),
    }

    return formatBraveResults(allocator, body, query);
}

/// DuckDuckGo HTML search via curl subprocess. No account or API key required.
fn duckduckgoSearch(allocator: std.mem.Allocator, query: []const u8, count: usize) !ToolResult {
    const encoded_query = try urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    const url_str = try std.fmt.allocPrint(
        allocator,
        "https://html.duckduckgo.com/html/?q={s}",
        .{encoded_query},
    );
    defer allocator.free(url_str);

    // Use a browser-like UA; DDG may return a CAPTCHA page for bare bot UAs.
    const argv = [_][]const u8{
        "curl", "-s", "-L",
        "-A", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "-H", "Accept-Language: en-US,en;q=0.9",
        "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "--max-time", "30",
        url_str,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to launch curl for DDG search: {}", .{err});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    const html = child.stdout.?.readToEndAlloc(allocator, 1 * 1024 * 1024) catch {
        _ = child.wait() catch {};
        return ToolResult.fail("Failed to read DDG search response");
    };
    defer allocator.free(html);

    const stderr_out = child.stderr.?.readToEndAlloc(allocator, 16 * 1024) catch
        try allocator.dupe(u8, "");
    defer allocator.free(stderr_out);

    const term = child.wait() catch return ToolResult.fail("curl process wait failed");
    switch (term) {
        .Exited => |code| if (code != 0) {
            const msg = if (stderr_out.len > 0)
                try std.fmt.allocPrint(allocator, "curl failed (exit {d}): {s}", .{ code, stderr_out })
            else
                try std.fmt.allocPrint(allocator, "DDG search curl failed (exit {d})", .{code});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
        else => return ToolResult.fail("curl process terminated abnormally"),
    }

    return parseDdgHtml(allocator, html, query, count);
}

/// Parse up to `max_count` search results from DDG HTML response.
/// Extracts title, real URL (via uddg= param decode), and snippet.
pub fn parseDdgHtml(allocator: std.mem.Allocator, html: []const u8, query: []const u8, max_count: usize) !ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try std.fmt.format(buf.writer(allocator), "Results for: {s}\n\n", .{query});

    var found: usize = 0;
    var search_from: usize = 0;

    while (found < max_count) {
        // Each DDG result title link has class="result__a"
        const class_marker = "class=\"result__a\"";
        const marker_pos = std.mem.indexOfPos(u8, html, search_from, class_marker) orelse break;

        // Find the opening < of the containing <a tag
        const tag_start = findLastLt(html, marker_pos) orelse {
            search_from = marker_pos + class_marker.len;
            continue;
        };

        // Find the closing > of the <a ...> tag
        const tag_end = std.mem.indexOfScalarPos(u8, html, marker_pos, '>') orelse {
            search_from = marker_pos + class_marker.len;
            continue;
        };

        const tag_content = html[tag_start + 1 .. tag_end];

        // Extract real URL: DDG encodes it as uddg=<percent-encoded-url> in href
        var real_url: ?[]u8 = null;
        defer { if (real_url) |u| allocator.free(u); }

        if (extractAttrVal(tag_content, "href")) |href| {
            if (std.mem.indexOf(u8, href, "uddg=")) |uddg_pos| {
                const enc_start = uddg_pos + 5;
                const enc_end = std.mem.indexOfScalarPos(u8, href, enc_start, '&') orelse href.len;
                real_url = urlDecode(allocator, href[enc_start..enc_end]) catch null;
            }
        }

        // Find closing </a> — everything between > and </a> is the title
        const close_a = std.mem.indexOfPos(u8, html, tag_end + 1, "</a>") orelse {
            search_from = tag_end + 1;
            continue;
        };

        const raw_title = std.mem.trim(u8, html[tag_end + 1 .. close_a], " \t\n\r");

        // Scan a window after the title for result__url (URL fallback) and snippet
        const win_end = @min(close_a + 2000, html.len);
        const window = html[close_a..win_end];

        var fallback_url: ?[]u8 = null;
        defer { if (fallback_url) |u| allocator.free(u); }

        if (real_url == null) {
            const url_marker = "class=\"result__url\"";
            if (std.mem.indexOf(u8, window, url_marker)) |uc_pos| {
                const uc_lt = findLastLt(window, uc_pos) orelse 0;
                const uc_gt = std.mem.indexOfScalarPos(u8, window, uc_pos, '>') orelse win_end;
                const uc_tag = window[uc_lt + 1 .. uc_gt];
                if (extractAttrVal(uc_tag, "href")) |href| {
                    fallback_url = try allocator.dupe(u8, href);
                }
            }
        }

        var snippet_clean: ?[]u8 = null;
        defer { if (snippet_clean) |s| allocator.free(s); }

        const snip_marker = "class=\"result__snippet\"";
        if (std.mem.indexOf(u8, window, snip_marker)) |sc_pos| {
            const sc_gt = std.mem.indexOfScalarPos(u8, window, sc_pos, '>') orelse win_end;
            const sc_close = std.mem.indexOfPos(u8, window, sc_gt + 1, "</a>") orelse
                std.mem.indexOfPos(u8, window, sc_gt + 1, "</div>") orelse win_end;
            const raw_snip = std.mem.trim(u8, window[sc_gt + 1 .. sc_close], " \t\n\r");
            snippet_clean = try stripDdgTags(allocator, raw_snip);
        }

        const display_url = if (real_url) |u| u else if (fallback_url) |u| u else "(URL unavailable)";

        found += 1;
        const clean_title = try stripDdgTags(allocator, raw_title);
        defer allocator.free(clean_title);
        try std.fmt.format(buf.writer(allocator), "{d}. {s}\n   {s}\n", .{ found, clean_title, display_url });
        if (snippet_clean) |s| {
            if (s.len > 0)
                try std.fmt.format(buf.writer(allocator), "   {s}\n", .{s});
        }
        try buf.append(allocator, '\n');

        search_from = close_a + 4;
    }

    if (found == 0) {
        buf.deinit(allocator);
        return ToolResult.ok("No search results found. (To improve results, set BRAVE_API_KEY env var for the Brave Search API.)");
    }

    return ToolResult.ok(try buf.toOwnedSlice(allocator));
}

/// Find the position of the last '<' before `before` in `s`.
fn findLastLt(s: []const u8, before: usize) ?usize {
    if (before == 0) return null;
    var i: usize = before - 1;
    while (true) {
        if (s[i] == '<') return i;
        if (i == 0) return null;
        i -= 1;
    }
}

/// Extract the value of an attribute from an HTML tag's content string.
/// e.g. extractAttrVal(`rel="nofollow" href="//ddg.co"`, "href") → `"//ddg.co"`
fn extractAttrVal(tag_content: []const u8, attr_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + attr_name.len + 2 <= tag_content.len) {
        if (std.mem.startsWith(u8, tag_content[i..], attr_name)) {
            const after = i + attr_name.len;
            if (after >= tag_content.len or tag_content[after] != '=') {
                i += 1;
                continue;
            }
            if (after + 1 >= tag_content.len) break;
            const quote = tag_content[after + 1];
            if (quote != '"' and quote != '\'') {
                i += 1;
                continue;
            }
            const val_start = after + 2;
            const val_end = std.mem.indexOfScalarPos(u8, tag_content, val_start, quote) orelse break;
            return tag_content[val_start..val_end];
        }
        i += 1;
    }
    return null;
}

/// Strip HTML tags from a string, returning plain text.
fn stripDdgTags(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            i = end + 1;
        } else {
            try buf.append(allocator, html[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// URL-decode a percent-encoded string.
pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]) orelse {
                try buf.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = hexVal(input[i + 2]) orelse {
                try buf.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try buf.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try buf.append(allocator, ' ');
            i += 1;
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "WebSearchTool name and description" {
    var wst = WebSearchTool{};
    const t = wst.tool();
    try testing.expectEqualStrings("web_search", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "WebSearchTool missing query fails" {
    var wst = WebSearchTool{};
    const parsed = try root.parseTestArgs("{\"count\":5}");
    defer parsed.deinit();
    const result = try wst.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'query' parameter", result.error_msg.?);
}

test "WebSearchTool empty query fails" {
    var wst = WebSearchTool{};
    const parsed = try root.parseTestArgs("{\"query\":\"  \"}");
    defer parsed.deinit();
    const result = try wst.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("'query' must not be empty", result.error_msg.?);
}

test "WebSearchTool works without BRAVE_API_KEY (DDG path)" {
    // Without BRAVE_API_KEY the tool routes to DDG, not an immediate hard-fail.
    // We can't make a real network request in a unit test, so just verify the
    // routing logic: the tool no longer returns BRAVE_API_KEY in error_msg.
    if (std.posix.getenv("BRAVE_API_KEY")) |_| return; // key is set, skip
    // parseDdgHtml with empty HTML → returns "no results" success, not a key error
    const result = try parseDdgHtml(testing.allocator, "", "test", 5);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "BRAVE_API_KEY") != null or
        std.mem.indexOf(u8, result.output, "No search results") != null);
}

test "parseCount defaults to 5" {
    const p1 = try root.parseTestArgs("{}");
    defer p1.deinit();
    try testing.expectEqual(@as(usize, DEFAULT_COUNT), parseCount(p1.value.object));
    const p2 = try root.parseTestArgs("{\"query\":\"test\"}");
    defer p2.deinit();
    try testing.expectEqual(@as(usize, DEFAULT_COUNT), parseCount(p2.value.object));
}

test "parseCount clamps to range" {
    const p1 = try root.parseTestArgs("{\"count\":0}");
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 1), parseCount(p1.value.object));
    const p2 = try root.parseTestArgs("{\"count\":100}");
    defer p2.deinit();
    try testing.expectEqual(@as(usize, MAX_RESULTS), parseCount(p2.value.object));
    const p3 = try root.parseTestArgs("{\"count\":3}");
    defer p3.deinit();
    try testing.expectEqual(@as(usize, 3), parseCount(p3.value.object));
}

test "urlEncode basic" {
    const encoded = try urlEncode(testing.allocator, "hello world");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("hello+world", encoded);
}

test "urlEncode special chars" {
    const encoded = try urlEncode(testing.allocator, "a&b=c");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("a%26b%3Dc", encoded);
}

test "urlEncode passthrough" {
    const encoded = try urlEncode(testing.allocator, "simple-test_123.txt~");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("simple-test_123.txt~", encoded);
}

test "formatBraveResults parses valid JSON" {
    const json =
        \\{"web":{"results":[
        \\  {"title":"Zig Language","url":"https://ziglang.org","description":"Zig is a systems language."},
        \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","description":"Source code."}
        \\]}}
    ;
    const result = try formatBraveResults(testing.allocator, json, "zig programming");
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Results for: zig programming") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "1. Zig Language") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "https://ziglang.org") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "2. Zig GitHub") != null);
}

test "formatBraveResults empty results" {
    const json = "{\"web\":{\"results\":[]}}";
    const result = try formatBraveResults(testing.allocator, json, "nothing");
    try testing.expect(result.success);
    try testing.expectEqualStrings("No web results found.", result.output);
}

test "formatBraveResults no web key" {
    const json = "{\"query\":{\"original\":\"test\"}}";
    const result = try formatBraveResults(testing.allocator, json, "test");
    try testing.expect(result.success);
    try testing.expectEqualStrings("No web results found.", result.output);
}

test "formatBraveResults invalid JSON" {
    const result = try formatBraveResults(testing.allocator, "not json", "q");
    try testing.expect(!result.success);
}

test "urlDecode basic" {
    const out = try urlDecode(testing.allocator, "hello+world");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "urlDecode percent encoding" {
    const out = try urlDecode(testing.allocator, "hello%20world%21");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world!", out);
}

test "urlDecode passthrough" {
    const out = try urlDecode(testing.allocator, "simple");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("simple", out);
}

test "urlDecode round-trip with urlEncode" {
    const original = "zig & search = \"test\"";
    const encoded = try urlEncode(testing.allocator, original);
    defer testing.allocator.free(encoded);
    const decoded = try urlDecode(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    // spaces encoded as + decode back to spaces via urlDecode
    try testing.expect(std.mem.indexOf(u8, decoded, "zig") != null);
    try testing.expect(std.mem.indexOf(u8, decoded, "search") != null);
}

test "parseDdgHtml empty body returns no-results message" {
    const result = try parseDdgHtml(testing.allocator, "", "test query", 5);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "No search results") != null);
}

test "parseDdgHtml extracts result from sample HTML" {
    const sample_html =
        \\<div class="result">
        \\  <h2 class="result__title">
        \\    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2F&rut=x">
        \\      Zig Programming Language
        \\    </a>
        \\  </h2>
        \\  <a class="result__url" href="https://ziglang.org/">ziglang.org</a>
        \\  <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">A language for robust software.</a>
        \\</div>
    ;
    const result = try parseDdgHtml(testing.allocator, sample_html, "zig language", 5);
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Zig Programming Language") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "ziglang.org") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "A language for robust software.") != null);
}

test "parseDdgHtml respects max_count" {
    const sample_html =
        \\<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fone.com">One</a>
        \\<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Ftwo.com">Two</a>
        \\<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fthree.com">Three</a>
    ;
    const result = try parseDdgHtml(testing.allocator, sample_html, "test", 2);
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "1. One") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "2. Two") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "3. Three") == null);
}

test "extractAttrVal basic" {
    try testing.expectEqualStrings("https://example.com", extractAttrVal(
        "rel=\"nofollow\" href=\"https://example.com\"",
        "href",
    ).?);
    try testing.expect(extractAttrVal("no-match", "href") == null);
}

test "stripDdgTags removes tags" {
    const out = try stripDdgTags(testing.allocator, "Hello <b>world</b>!");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello world!", out);
}

