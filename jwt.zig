const std = @import("std");
const testing = std.testing;
const ValueTree = std.json.ValueTree;
const Value = std.json.Value;
const base64url = std.base64.url_safe_no_pad;

const Algorithm = enum {
    HS256,

    pub fn jsonStringify(
        value: @This(),
        options: std.json.StringifyOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        try std.json.stringify(std.meta.tagName(value), options, writer);
    }
};

const JWTType = enum {
    JWS,
    JWE,
};

pub const SignatureOptions = struct {
    alg: Algorithm,
    key: []const u8,
    kid: ?[]const u8 = null,
};

pub fn encode(allocator: *std.mem.Allocator, payload: anytype, signatureOptions: SignatureOptions) ![]const u8 {
    var payload_json = std.ArrayList(u8).init(allocator);
    defer payload_json.deinit();

    try std.json.stringify(payload, .{}, payload_json.writer());

    var protected_header = std.json.ObjectMap.init(allocator);
    defer protected_header.deinit();
    try protected_header.put("alg", .{ .String = std.meta.tagName(signatureOptions.alg) });
    try protected_header.put("typ", .{ .String = "JWT" });
    if (signatureOptions.kid) |kid| {
        try protected_header.put("kid", .{ .String = kid });
    }

    var protected_header_json = std.ArrayList(u8).init(allocator);
    defer protected_header_json.deinit();

    try std.json.stringify(Value{ .Object = protected_header }, .{}, protected_header_json.writer());

    const payload_base64_len = base64url.Encoder.calcSize(payload_json.items.len);
    const protected_header_base64_len = base64url.Encoder.calcSize(protected_header_json.items.len);

    var jwt_text = std.ArrayList(u8).init(allocator);
    defer jwt_text.deinit();
    try jwt_text.resize(payload_base64_len + 1 + protected_header_base64_len);

    var protected_header_base64 = jwt_text.items[0..protected_header_base64_len];
    var payload_base64 = jwt_text.items[protected_header_base64_len + 1 ..][0..payload_base64_len];

    _ = base64url.Encoder.encode(protected_header_base64, protected_header_json.items);
    jwt_text.items[protected_header_base64_len] = '.';
    _ = base64url.Encoder.encode(payload_base64, payload_json.items);

    switch (signatureOptions.alg) {
        .HS256 => {
            const signature = generate_signature_hmac_sha256(signatureOptions.key, protected_header_base64, payload_base64);
            const signature_base64_len = base64url.Encoder.calcSize(signature.len);

            try jwt_text.resize(payload_base64_len + 1 + protected_header_base64_len + 1 + signature_base64_len);
            var signature_base64 = jwt_text.items[payload_base64_len + 1 + protected_header_base64_len + 1 ..][0..signature_base64_len];

            jwt_text.items[payload_base64_len + 1 + protected_header_base64_len] = '.';
            _ = base64url.Encoder.encode(signature_base64, &signature);
        },
    }

    return jwt_text.toOwnedSlice();
}

pub fn validate(allocator: *std.mem.Allocator, tokenText: []const u8, signatureOptions: SignatureOptions) !ValueTree {
    // 1.   Verify that the JWT contains at least one period ('.')
    //      character.
    // 2.   Let the Encoded JOSE Header be the portion of the JWT before the
    //      first period ('.') character.
    var end_of_jose_base64 = std.mem.indexOfScalar(u8, tokenText, '.') orelse return error.InvalidFormat;
    const jose_base64 = tokenText[0..end_of_jose_base64];

    // 3.   Base64url decode the Encoded JOSE Header following the
    //      restriction that no line breaks, whitespace, or other additional
    //      characters have been used.
    var jose_json = try allocator.alloc(u8, try base64url.Decoder.calcSizeForSlice(jose_base64));
    defer allocator.free(jose_json);
    try base64url.Decoder.decode(jose_json, jose_base64);

    // 4.   Verify that the resulting octet sequence is a UTF-8-encoded
    //      representation of a completely valid JSON object conforming to
    //      RFC 7159 [RFC7159]; let the JOSE Header be this JSON object.

    // TODO: Make sure the JSON parser confirms everything above

    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var cty_opt = @as(?[]const u8, null);
    defer if (cty_opt) |cty| allocator.free(cty);

    var jwt_tree = try parser.parse(jose_json);
    defer jwt_tree.deinit();

    // 5.   Verify that the resulting JOSE Header includes only parameters
    //      and values whose syntax and semantics are both understood and
    //      supported or that are specified as being ignored when not
    //      understood.

    var jwt_root = jwt_tree.root;
    if (jwt_root != .Object) return error.InvalidFormat;

    {
        var alg_val = jwt_root.Object.get("alg") orelse return error.InvalidFormat;
        if (alg_val != .String) return error.InvalidFormat;
        const alg = std.meta.stringToEnum(Algorithm, alg_val.String) orelse return error.InvalidAlgorithm;

        // Make sure that the algorithm matches: https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/
        if (alg != signatureOptions.alg) return error.InvalidAlgorithm;

        // TODO: Determine if "jku"/"jwk" need to be parsed and validated

        if (jwt_root.Object.get("crit")) |crit_val| {
            if (crit_val != .Array) return error.InvalidFormat;
            const crit = crit_val.Array;
            if (crit.items.len == 0) return error.InvalidFormat;

            // TODO: Implement or allow extensions?
            return error.UnknownExtension;
        }
    }

    // 6.   Determine whether the JWT is a JWS or a JWE using any of the
    //      methods described in Section 9 of [JWE].

    const jwt_type = determine_jwt_type: {
        // From Section 9 of the JWE specification:
        // > o  If the object is using the JWS Compact Serialization or the JWE
        // >    Compact Serialization, the number of base64url-encoded segments
        // >    separated by period ('.') characters differs for JWSs and JWEs.
        // >    JWSs have three segments separated by two period ('.') characters.
        // >    JWEs have five segments separated by four period ('.') characters.
        switch (std.mem.count(u8, tokenText, ".")) {
            2 => break :determine_jwt_type JWTType.JWS,
            4 => break :determine_jwt_type JWTType.JWE,
            else => return error.InvalidFormat,
        }
    };

    // 7.   Depending upon whether the JWT is a JWS or JWE, there are two
    //      cases:
    const message_base64 = get_message: {
        switch (jwt_type) {
            // If the JWT is a JWS, follow the steps specified in [JWS] for
            // validating a JWS.  Let the Message be the result of base64url
            // decoding the JWS Payload.
            .JWS => {
                var section_iter = std.mem.split(tokenText, ".");
                std.debug.assert(section_iter.next() != null);
                const payload_base64 = section_iter.next().?;
                const signature_base64 = section_iter.rest();

                var signature = try allocator.alloc(u8, try base64url.Decoder.calcSizeForSlice(signature_base64));
                defer allocator.free(signature);
                try base64url.Decoder.decode(signature, signature_base64);

                switch (signatureOptions.alg) {
                    .HS256 => {
                        const gen_sig = generate_signature_hmac_sha256(signatureOptions.key, jose_base64, payload_base64);
                        if (!std.mem.eql(u8, signature, &gen_sig)) {
                            return error.InvalidSignature;
                        }
                    },
                }

                break :get_message try allocator.dupe(u8, payload_base64);
            },
            .JWE => {
                // Else, if the JWT is a JWE, follow the steps specified in
                // [JWE] for validating a JWE.  Let the Message be the resulting
                // plaintext.
                return error.Unimplemented;
            },
        }
    };
    defer allocator.free(message_base64);

    // 8.   If the JOSE Header contains a "cty" (content type) value of
    //      "JWT", then the Message is a JWT that was the subject of nested
    //      signing or encryption operations.  In this case, return to Step
    //      1, using the Message as the JWT.
    if (jwt_root.Object.get("cty")) |cty_val| {
        if (cty_val != .String) return error.InvalidFormat;
        return error.Unimplemented;
    }

    // 9.   Otherwise, base64url decode the Message following the
    //      restriction that no line breaks, whitespace, or other additional
    //      characters have been used.
    var message = try allocator.alloc(u8, try base64url.Decoder.calcSizeForSlice(message_base64));
    defer allocator.free(message);
    try base64url.Decoder.decode(message, message_base64);

    // 10.  Verify that the resulting octet sequence is a UTF-8-encoded
    //      representation of a completely valid JSON object conforming to
    //      RFC 7159 [RFC7159]; let the JWT Claims Set be this JSON object.
    var message_parser = std.json.Parser.init(allocator, true);
    defer message_parser.deinit();

    var message_tree = try message_parser.parse(message);
    return message_tree;
}

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
pub fn generate_signature_hmac_sha256(key: []const u8, protectedHeaderBase64: []const u8, payloadBase64: []const u8) [HmacSha256.mac_length]u8 {
    var h = HmacSha256.init(key);
    h.update(protectedHeaderBase64);
    h.update(".");
    h.update(payloadBase64);

    var out: [HmacSha256.mac_length]u8 = undefined;
    h.final(&out);

    return out;
}

test "generate jws hmac sha-256" {
    const expected = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SVT7VUK8eOve-SCacPaU_bkzT3SFr9wk5EQciofG4Qo";
    const key_base64 = "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow";

    var key = try std.testing.allocator.alloc(u8, try base64url.Decoder.calcSizeForSlice(key_base64));
    defer std.testing.allocator.free(key);
    try base64url.Decoder.decode(key, key_base64);

    // {"sub": "1234567890","name": "John Doe","iat": 1516239022}
    const payload = .{
        .sub = "1234567890",
        .name = "John Doe",
        .iat = 1516239022,
    };

    const token = try encode(std.testing.allocator, payload, .{ .alg = .HS256, .key = key });
    defer std.testing.allocator.free(token);

    try std.testing.expectEqualSlices(u8, expected, token);
}

test "validate jws hmac sha-256" {
    const token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const key_base64 = "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow";

    var key = try std.testing.allocator.alloc(u8, try base64url.Decoder.calcSizeForSlice(key_base64));
    defer std.testing.allocator.free(key);
    try base64url.Decoder.decode(key, key_base64);

    var claims_tree = try validate(std.testing.allocator, token, .{ .alg = .HS256, .key = key });
    defer claims_tree.deinit();

    var claims = claims_tree.root;

    try std.testing.expectEqualSlices(u8, "joe", claims.Object.get("iss").?.String);
    try std.testing.expectEqual(@as(i64, 1300819380), claims.Object.get("exp").?.Integer);
    try std.testing.expectEqual(true, claims.Object.get("http://example.com/is_root").?.Bool);
}

test "generate and then validate jws hmac sha-256" {
    const key = "a jws hmac sha-256 test key";

    const payload = .{
        .sub = "1234567890",
        .name = "John Doe",
        .iat = @as(i64, 1516239022),
    };

    const signatureOptions = SignatureOptions{ .alg = .HS256, .key = key };

    const token = try encode(std.testing.allocator, payload, signatureOptions);
    defer std.testing.allocator.free(token);

    var claims_tree = try validate(std.testing.allocator, token, signatureOptions);
    defer claims_tree.deinit();

    var claims = claims_tree.root;

    try std.testing.expectEqualSlices(u8, payload.sub, claims.Object.get("sub").?.String);
    try std.testing.expectEqualSlices(u8, payload.name, claims.Object.get("name").?.String);
    try std.testing.expectEqual(payload.iat, claims.Object.get("iat").?.Integer);
}