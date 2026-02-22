package w10.plugins;

import w10.Context;
import w10.types.Types;
import w10.types.Hook;

/**
 * Cookie plugin for Warp10.
 *
 * Like @fastify/cookie: registers an OnRequest hook that eagerly parses the
 * Cookie request header and populates ctx.store["cookies"] with a
 * Map<String, String> of name→value pairs. Provides static helper methods
 * for reading and setting cookies.
 *
 * Usage:
 *
 *     // Register the plugin (once, typically at the app level)
 *     app.use(Cookie.create({}));
 *
 *     app.get("/", (ctx) -> {
 *         var sid = Cookie.get(ctx, "session_id");
 *         Cookie.set(ctx, "visited", "true", {path: "/", maxAge: 3600});
 *         ctx.text("Hello");
 *     });
 *
 * The plugin must be registered before any plugin that depends on cookies
 * (e.g. CSRF, session). The OnRequest hook runs before PreHandler hooks.
 */
class Cookie {
	/** Store key for the parsed cookies map */
	public static inline var STORE_KEY = "cookies";

	/**
	 * Create a Cookie plugin.
	 */
	public static function create(?config:CookieConfig):PluginFn {
		return (app:w10.Warp10) -> {
			app.addHook(OnRequest, (ctx:Context) -> {
				ctx.store.set(STORE_KEY, parseCookies(ctx));
			});
		};
	}

	// =========================================================================
	// Static helpers -- usable from handlers and other plugins
	// =========================================================================

	/**
	 * Get a cookie value by name.
	 *
	 * Returns null if the Cookie plugin is not registered or the cookie
	 * is not present. Safe to call regardless.
	 */
	public static function get(ctx:Context, name:String):Null<String> {
		var cookies:Dynamic = ctx.store.get(STORE_KEY);
		if (cookies == null) return null;
		var map:Map<String, String> = cast cookies;
		return map.get(name);
	}

	/**
	 * Set a cookie on the response.
	 *
	 * Appends a Set-Cookie header (does not overwrite other Set-Cookie
	 * headers, since HTTP requires them to be separate).
	 *
	 *     Cookie.set(ctx, "session", "abc123", {httpOnly: true, maxAge: 3600});
	 */
	public static function set(ctx:Context, name:String, value:String, ?opts:CookieOptions):Void {
		ctx.res.addHeader("Set-Cookie", name + "=" + value + serializeOpts(opts));
	}

	/**
	 * Clear a cookie by setting Max-Age=0.
	 *
	 *     Cookie.clear(ctx, "session", {path: "/"});
	 */
	public static function clear(ctx:Context, name:String, ?opts:CookieOptions):Void {
		ctx.res.addHeader("Set-Cookie", name + "=; Max-Age=0" + serializeOpts(opts));
	}

	/** Serialize cookie options into a Set-Cookie attribute string (e.g. "; Path=/; HttpOnly") */
	static function serializeOpts(opts:Null<CookieOptions>):String {
		if (opts == null) return "";
		var s = "";
		if (opts.path != null) s += "; Path=" + opts.path;
		if (opts.domain != null) s += "; Domain=" + opts.domain;
		if (opts.maxAge != null) s += "; Max-Age=" + Std.string(opts.maxAge);
		if (opts.httpOnly == true) s += "; HttpOnly";
		if (opts.secure == true) s += "; Secure";
		if (opts.sameSite != null) s += "; SameSite=" + opts.sameSite;
		return s;
	}

	// =========================================================================
	// Internal parsing
	// =========================================================================

	/** Parse the Cookie request header into a Map */
	static function parseCookies(ctx:Context):Map<String, String> {
		var result = new Map<String, String>();
		var header = ctx.req.getHeader("cookie");
		if (header == null) return result;

		// Split on ";" (standard delimiter), trim whitespace
		var pairs = header.split(";");
		for (pair in pairs) {
			var trimmed = StringTools.trim(pair);
			var eqIdx = trimmed.indexOf("=");
			if (eqIdx > 0) {
				var key = trimmed.substring(0, eqIdx);
				var value = trimmed.substring(eqIdx + 1);
				result.set(key, value);
			}
		}
		return result;
	}
}

/** Options for setting a cookie via Cookie.set() */
typedef CookieOptions = {
	/** Cookie Path attribute */
	?path:String,

	/** Cookie Domain attribute */
	?domain:String,

	/** Cookie Max-Age in seconds */
	?maxAge:Int,

	/** Cookie HttpOnly flag (not accessible to JavaScript) */
	?httpOnly:Bool,

	/** Cookie Secure flag (only sent over HTTPS) */
	?secure:Bool,

	/** Cookie SameSite attribute ("Strict", "Lax", or "None") */
	?sameSite:String,
};

/** Configuration for the Cookie plugin. */
typedef CookieConfig = {
	// Reserved for future options (custom parser, signing, etc.)
};
