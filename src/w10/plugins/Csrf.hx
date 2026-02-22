package w10.plugins;

import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.crypto.Hmac;
import w10.Context;
import w10.types.Types;
import w10.types.HttpMethod;
import w10.types.Hook;
import w10.utils.Crypto;
import w10.plugins.Cookie;
import w10.plugins.FormBody;

/**
 * CSRF protection plugin for Warp10.
 *
 * Implements the Double Submit Cookie pattern:
 *
 *   1. A secret is generated and stored in a cookie (_csrf)
 *   2. A token derived from the secret (salt + HMAC-SHA256) is sent
 *      to the client via the X-CSRF-Token response header and stored
 *      in ctx.store["csrfToken"]
 *   3. On state-changing requests (POST, PUT, DELETE, PATCH), the
 *      client must send the token back in the X-CSRF-Token header
 *      or in the form body field "_csrf"
 *   4. The server validates the token against the cookie secret
 *
 * Dependencies: Requires the Cookie plugin to be registered before CSRF.
 * If FormBody or Multipart plugins are registered, the CSRF token can
 * also be read from the form body (for HTML form submissions).
 *
 * Usage:
 *
 *     app.register((scope) -> {
 *         scope.use(Cookie.create({}));     // required
 *         scope.use(FormBody.create({}));   // optional, for HTML forms
 *         scope.use(Csrf.create({}));
 *         scope.get("/form", formHandler);
 *         scope.post("/submit", submitHandler);
 *     });
 *
 *     // In your handler, access the token for HTML embedding:
 *     //   var token = ctx.store.get("csrfToken");
 *     //   ctx.html('<input type="hidden" name="_csrf" value="$token">');
 */

/** Configuration for the CSRF plugin. */
typedef CsrfConfig = {
	/** Cookie name for the CSRF secret (default: "_csrf") */
	?cookieName:String,

	/** Request header name to read the token from (default: "x-csrf-token").
	 *  Compared case-insensitively since Warp10 lowercases all request headers. */
	?headerName:String,

	/** Form body field name to read the token from as a fallback (default: "_csrf").
	 *  Used when the token is submitted via a hidden form input instead of a header. */
	?fieldName:String,

	/** Cookie Path attribute (default: "/") */
	?cookiePath:String,

	/** Cookie Secure attribute -- set true when using HTTPS (default: false) */
	?cookieSecure:Bool,

	/** Cookie SameSite attribute (default: "Strict") */
	?cookieSameSite:String,

	/** Cookie Max-Age in seconds (default: 86400 = 24 hours) */
	?cookieMaxAge:Int,
};

class Csrf {
	/**
	 * Create a CSRF protection plugin.
	 */
	public static function create(?config:CsrfConfig):PluginFn {
		var cfg:CsrfConfig = config != null ? config : {};
		var cookieName = cfg.cookieName != null ? cfg.cookieName : "_csrf";
		var headerName = cfg.headerName != null ? cfg.headerName : "x-csrf-token";
		var fieldName = cfg.fieldName != null ? cfg.fieldName : "_csrf";
		var cookiePath = cfg.cookiePath != null ? cfg.cookiePath : "/";
		var cookieSecure = cfg.cookieSecure != null ? cfg.cookieSecure : false;
		var cookieSameSite = cfg.cookieSameSite != null ? cfg.cookieSameSite : "Strict";
		var cookieMaxAge = cfg.cookieMaxAge != null ? cfg.cookieMaxAge : 86400;

		// Pre-create the HMAC instance (stateless, reusable)
		var hmac = new Hmac(SHA256);

		return (app:w10.Warp10) -> {
			app.addHook(PreHandler, (ctx:Context) -> {
				handleCsrf(ctx, hmac, cookieName, headerName, fieldName, cookiePath, cookieSecure, cookieSameSite, cookieMaxAge);
			});
		};
	}

	/**
	 * CSRF PreHandler hook.
	 *
	 * - Safe methods (GET, HEAD, OPTIONS): generate/refresh token
	 * - Unsafe methods (POST, PUT, DELETE, PATCH): validate token, then refresh
	 */
	static function handleCsrf(
		ctx:Context,
		hmac:Hmac,
		cookieName:String,
		headerName:String,
		fieldName:String,
		cookiePath:String,
		cookieSecure:Bool,
		cookieSameSite:String,
		cookieMaxAge:Int
	):Void {
		var method = ctx.req.method;

		if (isSafeMethod(method)) {
			// Safe method: ensure secret exists and provide token
			var secret = getOrCreateSecret(ctx, hmac, cookieName, cookiePath, cookieSecure, cookieSameSite, cookieMaxAge);
			if (secret != null) {
				var token = generateToken(hmac, secret);
				ctx.res.header("X-CSRF-Token", token);
				ctx.store.set("csrfToken", token);
			}
		} else {
			// Unsafe method: validate token
			var secret = Cookie.get(ctx, cookieName);
			if (secret == null) {
				ctx.status(403).json({error: "CSRF token missing", message: "No CSRF cookie found"});
				return;
			}

			// Check header first, then fall back to form body field.
			// HTML forms cannot set custom headers, so the token is
			// typically submitted as a hidden <input name="_csrf">.
			// FormBody.get() works for both urlencoded and multipart
			// (Multipart merges text fields into the formBody store key).
			var submittedToken = ctx.getHeader(headerName);
			if (submittedToken == null) {
				submittedToken = FormBody.get(ctx, fieldName);
			}
			if (submittedToken == null) {
				ctx.status(403).json({error: "CSRF token missing", message: "No CSRF token in header or form body"});
				return;
			}

			if (!validateToken(hmac, secret, submittedToken)) {
				ctx.status(403).json({error: "CSRF token invalid", message: "Token validation failed"});
				return;
			}

			// Validation passed -- generate fresh token for the response
			var token = generateToken(hmac, secret);
			ctx.res.header("X-CSRF-Token", token);
			ctx.store.set("csrfToken", token);
		}
	}

	/**
	 * Check if an HTTP method is "safe" (does not modify state).
	 */
	static function isSafeMethod(method:HttpMethod):Bool {
		return switch (method) {
			case Get: true;
			case Head: true;
			case Options: true;
			default: false;
		};
	}

	/**
	 * Get existing secret from cookie or create a new one.
	 * Sets the cookie on the response if a new secret is generated.
	 */
	static function getOrCreateSecret(
		ctx:Context,
		hmac:Hmac,
		cookieName:String,
		cookiePath:String,
		cookieSecure:Bool,
		cookieSameSite:String,
		cookieMaxAge:Int
	):Null<String> {
		var existing = Cookie.get(ctx, cookieName);
		if (existing != null) return existing;

		// Generate new secret: 32 random bytes, Base64url-encoded
		var secretBytes = Crypto.randomBytes(32);
		if (secretBytes == null) return null;

		var secret = Base64.urlEncode(secretBytes);

		// Set the cookie via Cookie plugin
		Cookie.set(ctx, cookieName, secret, {
			path: cookiePath,
			httpOnly: true,
			sameSite: cookieSameSite,
			maxAge: cookieMaxAge,
			secure: cookieSecure,
		});

		return secret;
	}

	/**
	 * Generate a CSRF token from a secret.
	 *
	 * Token format: salt.signature
	 *   - salt: 32 random bytes, Base64url-encoded
	 *   - signature: HMAC-SHA256(secret, salt), Base64url-encoded
	 */
	static function generateToken(hmac:Hmac, secret:String):Null<String> {
		var saltBytes = Crypto.randomBytes(32);
		if (saltBytes == null) return null;

		var salt = Base64.urlEncode(saltBytes);
		var signature = computeSignature(hmac, secret, salt);

		return salt + "." + signature;
	}

	/**
	 * Validate a submitted CSRF token against the secret.
	 *
	 * Splits the token into salt + signature, recomputes the expected
	 * signature, and compares using constant-time equality.
	 */
	static function validateToken(hmac:Hmac, secret:String, token:String):Bool {
		var dotIdx = token.indexOf(".");
		if (dotIdx <= 0 || dotIdx >= token.length - 1) return false;

		var salt = token.substring(0, dotIdx);
		var submittedSig = token.substring(dotIdx + 1);

		var expectedSig = computeSignature(hmac, secret, salt);

		// Constant-time comparison on the raw bytes
		var submittedBytes = Bytes.ofString(submittedSig);
		var expectedBytes = Bytes.ofString(expectedSig);

		return Crypto.constantTimeEqual(submittedBytes, expectedBytes);
	}

	/**
	 * Compute HMAC-SHA256(secret, salt) and return as Base64url string.
	 */
	static function computeSignature(hmac:Hmac, secret:String, salt:String):String {
		var keyBytes = Bytes.ofString(secret);
		var msgBytes = Bytes.ofString(salt);
		var sigBytes = hmac.make(keyBytes, msgBytes);
		return Base64.urlEncode(sigBytes);
	}
}
