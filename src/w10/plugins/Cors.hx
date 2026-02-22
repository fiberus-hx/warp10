package w10.plugins;

import w10.Context;
import w10.types.Types;
import w10.types.Hook;
import w10.types.HttpMethod;

/**
 * CORS (Cross-Origin Resource Sharing) plugin for Warp10.
 *
 * Like @fastify/cors: registers an OnRequest hook that handles CORS
 * preflight (OPTIONS) requests and sets appropriate Access-Control-*
 * response headers on all cross-origin requests.
 *
 * Preflight requests are intercepted in the hook, responded to with
 * a configurable success status (default 204), and short-circuited
 * so no route handler runs. Non-preflight requests with an Origin
 * header get CORS response headers added before continuing.
 *
 * Usage:
 *
 *     // Allow all origins (wildcard)
 *     app.use(Cors.create());
 *
 *     // Reflect request origin back (needed with credentials)
 *     app.use(Cors.create({origin: true, credentials: true}));
 *
 *     // Whitelist specific origins
 *     app.use(Cors.create({origin: ["https://example.com", "https://app.example.com"]}));
 *
 *     // Regex matching
 *     app.use(Cors.create({origin: ~/\.example\.com$/}));
 *
 *     // Custom function
 *     app.use(Cors.create({origin: (origin) -> StringTools.endsWith(origin, ".example.com")}));
 *
 *     // Scoped -- only applies to routes inside this block
 *     app.register((api) -> {
 *         api.use(Cors.create({origin: "https://app.example.com"}));
 *         api.get("/data", handler);
 *     });
 */
class Cors {
	/**
	 * Create a CORS plugin.
	 */
	public static function create(?config:CorsConfig):PluginFn {
		var cfg:CorsConfig = config != null ? config : {};

		// Resolve origin config (default: "*")
		var originCfg:Dynamic = cfg.origin != null ? cfg.origin : "*";

		// Resolve methods (default: common methods)
		var methodsStr = toHeaderString(cfg.methods, "GET,HEAD,POST,PUT,DELETE,PATCH");

		// Resolve allowed headers (null = reflect Access-Control-Request-Headers)
		var allowedHeadersStr = toHeaderString(cfg.allowedHeaders, null);

		// Resolve exposed headers (null = none)
		var exposedHeadersStr = toHeaderString(cfg.exposedHeaders, null);

		// Boolean/int options with defaults
		var credentials = cfg.credentials != null ? cfg.credentials : false;
		var maxAge = cfg.maxAge;
		var optionsStatus = cfg.optionsSuccessStatus != null ? cfg.optionsSuccessStatus : 204;
		var preflight = cfg.preflight != null ? cfg.preflight : true;
		var strictPreflight = cfg.strictPreflight != null ? cfg.strictPreflight : true;

		// Pre-compute: is origin a static wildcard "*"?
		var isStaticWildcard = Std.isOfType(originCfg, String) && (cast(originCfg, String) : String) == "*";

		// Pre-stringify maxAge
		var maxAgeStr:Null<String> = maxAge != null ? Std.string(maxAge) : null;

		return (app:w10.Warp10) -> {
			app.addHook(OnRequest, (ctx:Context) -> {
				handleCors(ctx, originCfg, isStaticWildcard, methodsStr, allowedHeadersStr, exposedHeadersStr, credentials,
					maxAgeStr, optionsStatus, preflight, strictPreflight);
			});
		};
	}

	/**
	 * OnRequest hook: handle CORS for incoming requests.
	 */
	static function handleCors(
		ctx:Context,
		originCfg:Dynamic,
		isStaticWildcard:Bool,
		methodsStr:String,
		allowedHeadersStr:Null<String>,
		exposedHeadersStr:Null<String>,
		credentials:Bool,
		maxAgeStr:Null<String>,
		optionsStatus:Int,
		preflight:Bool,
		strictPreflight:Bool
	):Void {
		// No Origin header = not a CORS request; skip
		var requestOrigin = ctx.getHeader("origin");
		if (requestOrigin == null) return;

		// Resolve whether this origin is allowed and what value to send back
		var result = resolveOrigin(requestOrigin, originCfg);
		if (!result.allowed) return;

		var originValue = result.value;

		// Vary: Origin when origin is not a static wildcard
		// (caches must key on Origin when the response differs per origin)
		if (!isStaticWildcard) {
			ctx.res.header("Vary", "Origin");
		}

		// Preflight (OPTIONS) handling
		if (ctx.req.method == Options && preflight) {
			// Strict preflight: require Access-Control-Request-Method
			if (strictPreflight) {
				var acrm = ctx.getHeader("access-control-request-method");
				if (acrm == null) {
					ctx.status(400).json({error: "Missing Access-Control-Request-Method header"});
					return;
				}
			}

			ctx.res.header("Access-Control-Allow-Origin", originValue);
			ctx.res.header("Access-Control-Allow-Methods", methodsStr);

			// Allowed headers: use configured value or reflect request headers
			var headers = allowedHeadersStr;
			if (headers == null) {
				headers = ctx.getHeader("access-control-request-headers");
				// When reflecting, add Vary: Access-Control-Request-Headers
				if (headers != null && !isStaticWildcard) {
					ctx.res.header("Vary", "Origin, Access-Control-Request-Headers");
				}
			}
			if (headers != null) {
				ctx.res.header("Access-Control-Allow-Headers", headers);
			}

			if (credentials) {
				ctx.res.header("Access-Control-Allow-Credentials", "true");
			}

			if (maxAgeStr != null) {
				ctx.res.header("Access-Control-Max-Age", maxAgeStr);
			}

			// Short-circuit: respond immediately, no route handler runs
			ctx.sendEmpty(optionsStatus);
			return;
		}

		// Actual (non-preflight) request: set CORS response headers
		ctx.res.header("Access-Control-Allow-Origin", originValue);

		if (credentials) {
			ctx.res.header("Access-Control-Allow-Credentials", "true");
		}

		if (exposedHeadersStr != null) {
			ctx.res.header("Access-Control-Expose-Headers", exposedHeadersStr);
		}

		// Continue to route handler
	}

	/**
	 * Determine if a request origin is allowed by the config and what
	 * Access-Control-Allow-Origin value to return.
	 *
	 * Supported origin config types:
	 *   - String "*"             -> wildcard (allow all)
	 *   - String (other)        -> exact match
	 *   - Bool true             -> reflect request origin
	 *   - Bool false            -> disallow
	 *   - Array<String>         -> whitelist
	 *   - EReg                  -> regex match
	 *   - (String) -> Bool      -> custom function
	 */
	static function resolveOrigin(requestOrigin:String, originCfg:Dynamic):{allowed:Bool, value:String} {
		// Bool check first (before String, since we use Std.isOfType)
		if (Std.isOfType(originCfg, Bool)) {
			if ((cast originCfg : Bool)) {
				// true = reflect request origin
				return {allowed: true, value: requestOrigin};
			} else {
				// false = disabled
				return {allowed: false, value: ""};
			}
		}

		// String: wildcard or exact match
		if (Std.isOfType(originCfg, String)) {
			var s:String = cast originCfg;
			if (s == "*") {
				return {allowed: true, value: "*"};
			}
			// Exact match
			if (s == requestOrigin) {
				return {allowed: true, value: requestOrigin};
			}
			return {allowed: false, value: ""};
		}

		// Array<String>: whitelist
		if (Std.isOfType(originCfg, Array)) {
			var arr:Array<Dynamic> = cast originCfg;
			var i = 0;
			while (i < arr.length) {
				if (Std.isOfType(arr[i], String) && (cast(arr[i], String) : String) == requestOrigin) {
					return {allowed: true, value: requestOrigin};
				}
				i++;
			}
			return {allowed: false, value: ""};
		}

		// EReg: regex match
		if (Std.isOfType(originCfg, EReg)) {
			var regex:EReg = cast originCfg;
			if (regex.match(requestOrigin)) {
				return {allowed: true, value: requestOrigin};
			}
			return {allowed: false, value: ""};
		}

		// Function: (String) -> Bool
		// Haxe doesn't let us Std.isOfType on function types reliably,
		// so we try the function call as a fallback after exhausting
		// all other types. If the config is none of the above, assume
		// it's a function.
		try {
			var fn:(String) -> Bool = cast originCfg;
			if (fn(requestOrigin)) {
				return {allowed: true, value: requestOrigin};
			}
			return {allowed: false, value: ""};
		} catch (_:Dynamic) {
			// Unknown type -- disallow
			return {allowed: false, value: ""};
		}
	}

	/**
	 * Convert a Dynamic value (String, Array<String>, or null) to a
	 * comma-separated header string. Returns defaultVal if value is null.
	 */
	static function toHeaderString(value:Dynamic, defaultVal:Null<String>):Null<String> {
		if (value == null) return defaultVal;

		if (Std.isOfType(value, String)) {
			return cast value;
		}

		if (Std.isOfType(value, Array)) {
			var arr:Array<Dynamic> = cast value;
			var result = "";
			var i = 0;
			while (i < arr.length) {
				if (i > 0) result += ",";
				result += Std.string(arr[i]);
				i++;
			}
			return result;
		}

		return Std.string(value);
	}
}

/** Configuration for the CORS plugin. */
typedef CorsConfig = {
	/**
	 * Origin(s) to allow. Accepts:
	 *   - "*"              Wildcard, allow all origins (default)
	 *   - true             Reflect the request Origin header back
	 *   - false            Disable CORS
	 *   - "https://..."    Exact origin string match
	 *   - ["https://a.com", "https://b.com"]  Whitelist of origins
	 *   - ~/\.example\.com$/  EReg regex match
	 *   - (origin:String) -> Bool  Custom function
	 *
	 * Note: wildcard "*" cannot be combined with credentials: true.
	 * Default: "*"
	 */
	?origin:Dynamic,

	/**
	 * Allowed HTTP methods for preflight. String or Array<String>.
	 * Default: "GET,HEAD,POST,PUT,DELETE,PATCH"
	 */
	?methods:Dynamic,

	/**
	 * Allowed request headers for preflight. String or Array<String>.
	 * When null (default), reflects the Access-Control-Request-Headers
	 * header from the preflight request.
	 */
	?allowedHeaders:Dynamic,

	/**
	 * Response headers to expose to the browser. String or Array<String>.
	 * Default: none
	 */
	?exposedHeaders:Dynamic,

	/**
	 * Whether to include Access-Control-Allow-Credentials: true.
	 * When true, the browser allows JavaScript to read the response
	 * and send credentials (cookies, auth headers) cross-origin.
	 * Cannot be combined with origin: "*".
	 * Default: false
	 */
	?credentials:Bool,

	/**
	 * Preflight cache duration in seconds.
	 * Sets Access-Control-Max-Age on preflight responses.
	 * Default: not set (browser uses its own default)
	 */
	?maxAge:Int,

	/**
	 * HTTP status code for successful preflight responses.
	 * Default: 204
	 */
	?optionsSuccessStatus:Int,

	/**
	 * Whether to handle preflight OPTIONS requests automatically.
	 * When false, OPTIONS requests pass through to the route handler.
	 * Default: true
	 */
	?preflight:Bool,

	/**
	 * Require Access-Control-Request-Method header on OPTIONS requests.
	 * Returns 400 Bad Request if missing. This distinguishes real CORS
	 * preflights from plain OPTIONS requests.
	 * Default: true
	 */
	?strictPreflight:Bool,
};
