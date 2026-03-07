package w10.plugins;

import w10.Context;
import w10.types.Types;
import w10.types.Hook;

/**
 * htmx integration helpers for Warp10.
 *
 * Provides static methods for detecting htmx requests, reading htmx
 * request headers, and setting htmx response headers. Can optionally
 * be registered as a plugin via create() to pre-parse all HX-* request
 * headers into a typed struct in ctx.store for faster repeated access.
 *
 * htmx is a client-side library that issues AJAX requests and swaps
 * HTML fragments into the DOM. It communicates with the server via
 * special HTTP headers (HX-Request, HX-Target, HX-Trigger, etc.).
 * Servers respond with HTML fragments, not JSON.
 *
 * Usage (static helpers, no plugin registration needed):
 *
 *     app.get("/items", (ctx) -> {
 *         if (Htmx.isHtmx(ctx)) {
 *             ctx.html("<li>New item</li>");
 *         } else {
 *             ctx.html("<html>...</html>");
 *         }
 *     });
 *
 * Usage (as plugin with pre-parsed headers):
 *
 *     app.use(Htmx.create({}));
 *
 *     app.get("/items", (ctx) -> {
 *         var hx = Htmx.getInfo(ctx);
 *         if (hx != null && hx.request) {
 *             Htmx.trigger(ctx, "itemsLoaded");
 *             ctx.html("<li>New item</li>");
 *         }
 *     });
 *
 * Response header helpers:
 *
 *     app.post("/items", (ctx) -> {
 *         // ... create item ...
 *         Htmx.trigger(ctx, '{"itemAdded": {"id": 42}}');
 *         Htmx.reswap(ctx, "afterbegin");
 *         ctx.html("<li>New item</li>");
 *     });
 */
class Htmx {
	/** Store key for the pre-parsed htmx request headers */
	public static inline var STORE_KEY = "htmx";

	// =========================================================================
	// Plugin registration (optional)
	// =========================================================================

	/**
	 * Create an Htmx plugin.
	 *
	 * Registers an OnRequest hook that pre-parses all HX-* request
	 * headers into an HtmxInfo struct stored in ctx.store["htmx"].
	 * This avoids repeated header lookups when multiple helpers are
	 * called on the same request.
	 *
	 * Registration is optional -- all static helper methods work
	 * without the plugin by reading headers directly from the request.
	 */
	public static function create(?config:HtmxConfig):PluginFn {
		return (app:w10.Warp10) -> {
			app.addHook(OnRequest, (ctx:Context) -> {
				ctx.store.set(STORE_KEY, parseHtmxHeaders(ctx));
			});
		};
	}

	// =========================================================================
	// Pre-parsed info access
	// =========================================================================

	/**
	 * Get the pre-parsed htmx request headers.
	 *
	 * Returns null if the Htmx plugin was not registered via create().
	 * When registered, returns the HtmxInfo struct populated by the
	 * OnRequest hook.
	 */
	public static function getInfo(ctx:Context):Null<HtmxInfo> {
		var info:Dynamic = ctx.store.get(STORE_KEY);
		if (info == null) return null;
		return cast info;
	}

	// =========================================================================
	// Request detection (read headers directly)
	// =========================================================================

	/**
	 * Check if the current request was made by htmx.
	 * htmx sets HX-Request: true on every AJAX request.
	 */
	public static function isHtmx(ctx:Context):Bool {
		return ctx.getHeader("hx-request") == "true";
	}

	/**
	 * Check if the request is via an element using hx-boost.
	 * Boosted requests convert regular links/forms into AJAX.
	 */
	public static function isBoosted(ctx:Context):Bool {
		return ctx.getHeader("hx-boosted") == "true";
	}

	/**
	 * Check if this is a history restoration request.
	 * Sent when the browser navigates back and the page is not
	 * found in htmx's local history cache.
	 */
	public static function isHistoryRestore(ctx:Context):Bool {
		return ctx.getHeader("hx-history-restore-request") == "true";
	}

	/**
	 * Get the id of the target element for the htmx swap.
	 * Returns null if not set (e.g. non-htmx request).
	 */
	public static function target(ctx:Context):Null<String> {
		return ctx.getHeader("hx-target");
	}

	/**
	 * Get the name attribute of the element that triggered the request.
	 */
	public static function triggerName(ctx:Context):Null<String> {
		return ctx.getHeader("hx-trigger-name");
	}

	/**
	 * Get the id of the element that triggered the request.
	 */
	public static function triggerId(ctx:Context):Null<String> {
		return ctx.getHeader("hx-trigger");
	}

	/**
	 * Get the current URL of the browser when the request was made.
	 */
	public static function currentUrl(ctx:Context):Null<String> {
		return ctx.getHeader("hx-current-url");
	}

	/**
	 * Get the user response to an hx-prompt.
	 */
	public static function prompt(ctx:Context):Null<String> {
		return ctx.getHeader("hx-prompt");
	}

	// =========================================================================
	// Response headers
	// =========================================================================

	/**
	 * Push a URL into the browser history stack.
	 * Pass "false" to prevent the URL from being pushed.
	 *
	 *     Htmx.pushUrl(ctx, "/new-page");
	 */
	public static function pushUrl(ctx:Context, url:String):Void {
		ctx.res.header("HX-Push-Url", url);
	}

	/**
	 * Replace the current URL in the browser location bar
	 * without adding a new history entry.
	 * Pass "false" to prevent the URL from being replaced.
	 *
	 *     Htmx.replaceUrl(ctx, "/updated-page");
	 */
	public static function replaceUrl(ctx:Context, url:String):Void {
		ctx.res.header("HX-Replace-Url", url);
	}

	/**
	 * Trigger a client-side redirect to a new location.
	 * This performs a full page load (not an htmx swap).
	 *
	 *     Htmx.redirect(ctx, "/login");
	 */
	public static function redirect(ctx:Context, url:String):Void {
		ctx.res.header("HX-Redirect", url);
	}

	/**
	 * Trigger a full page refresh on the client.
	 */
	public static function refresh(ctx:Context):Void {
		ctx.res.header("HX-Refresh", "true");
	}

	/**
	 * Override the swap strategy for this response.
	 * Accepts any hx-swap value: innerHTML, outerHTML, beforebegin,
	 * afterbegin, beforeend, afterend, delete, none.
	 *
	 *     Htmx.reswap(ctx, "outerHTML");
	 *     Htmx.reswap(ctx, "afterbegin swap:1s");
	 */
	public static function reswap(ctx:Context, strategy:String):Void {
		ctx.res.header("HX-Reswap", strategy);
	}

	/**
	 * Override the target element for the swap.
	 * Takes a CSS selector.
	 *
	 *     Htmx.retarget(ctx, "#content");
	 */
	public static function retarget(ctx:Context, selector:String):Void {
		ctx.res.header("HX-Retarget", selector);
	}

	/**
	 * Select a subset of the response to swap in.
	 * Takes a CSS selector. Overrides any hx-select on the trigger element.
	 *
	 *     Htmx.reselect(ctx, "#main-content");
	 */
	public static function reselect(ctx:Context, selector:String):Void {
		ctx.res.header("HX-Reselect", selector);
	}

	/**
	 * Client-side navigation without a full page reload.
	 *
	 * Simple form (path only):
	 *     Htmx.location(ctx, "/new-page");
	 *
	 * With options (path + target/swap/etc.):
	 *     Htmx.location(ctx, "/new-page", {target: "#content", swap: "innerHTML"});
	 */
	public static function location(ctx:Context, path:String, ?opts:HtmxLocationOpts):Void {
		if (opts == null) {
			ctx.res.header("HX-Location", path);
		} else {
			var obj:Dynamic = {path: path};
			if (opts.target != null) Reflect.setField(obj, "target", opts.target);
			if (opts.swap != null) Reflect.setField(obj, "swap", opts.swap);
			if (opts.select != null) Reflect.setField(obj, "select", opts.select);
			if (opts.values != null) Reflect.setField(obj, "values", opts.values);
			if (opts.headers != null) Reflect.setField(obj, "headers", opts.headers);
			ctx.res.header("HX-Location", haxe.Json.stringify(obj));
		}
	}

	/**
	 * Trigger client-side events after the response is received.
	 *
	 * Simple event (no detail):
	 *     Htmx.trigger(ctx, "itemAdded");
	 *
	 * Multiple events with detail (pass JSON string):
	 *     Htmx.trigger(ctx, '{"itemAdded":{"id":42},"listUpdated":null}');
	 */
	public static function trigger(ctx:Context, events:String):Void {
		ctx.res.header("HX-Trigger", events);
	}

	/**
	 * Trigger client-side events after the settle step.
	 * Same format as trigger().
	 */
	public static function triggerAfterSettle(ctx:Context, events:String):Void {
		ctx.res.header("HX-Trigger-After-Settle", events);
	}

	/**
	 * Trigger client-side events after the swap step.
	 * Same format as trigger().
	 */
	public static function triggerAfterSwap(ctx:Context, events:String):Void {
		ctx.res.header("HX-Trigger-After-Swap", events);
	}

	// =========================================================================
	// Response helpers
	// =========================================================================

	/**
	 * Send HTTP 286 to stop htmx polling.
	 *
	 * When an element uses hx-trigger="every Ns" for polling, the server
	 * can respond with status 286 to tell htmx to stop polling that element.
	 */
	public static function stopPolling(ctx:Context):Void {
		ctx.status(286).text("");
	}

	// =========================================================================
	// Internal
	// =========================================================================

	/** Parse all HX-* request headers into an HtmxInfo struct */
	static function parseHtmxHeaders(ctx:Context):HtmxInfo {
		return {
			request: ctx.getHeader("hx-request") == "true",
			boosted: ctx.getHeader("hx-boosted") == "true",
			historyRestore: ctx.getHeader("hx-history-restore-request") == "true",
			target: ctx.getHeader("hx-target"),
			triggerName: ctx.getHeader("hx-trigger-name"),
			triggerId: ctx.getHeader("hx-trigger"),
			currentUrl: ctx.getHeader("hx-current-url"),
			prompt: ctx.getHeader("hx-prompt"),
		};
	}
}

// =============================================================================
// Typedefs
// =============================================================================

/**
 * Pre-parsed htmx request headers.
 *
 * Populated by the OnRequest hook when the Htmx plugin is registered
 * via create(). Access via Htmx.getInfo(ctx).
 */
typedef HtmxInfo = {
	/** Whether this is an htmx AJAX request (HX-Request: true) */
	request:Bool,

	/** Whether this request is via hx-boost (HX-Boosted: true) */
	boosted:Bool,

	/** Whether this is a history restoration request */
	historyRestore:Bool,

	/** The id of the target element, or null */
	?target:String,

	/** The name of the triggered element, or null */
	?triggerName:String,

	/** The id of the triggered element, or null */
	?triggerId:String,

	/** The browser's current URL at request time, or null */
	?currentUrl:String,

	/** The user's response to hx-prompt, or null */
	?prompt:String,
};

/**
 * Options for HX-Location response header.
 *
 * When provided, the header value is JSON-encoded with the path
 * and these options. htmx will navigate to the path and swap
 * content according to the specified options.
 */
typedef HtmxLocationOpts = {
	/** CSS selector for the target element */
	?target:String,

	/** Swap strategy (innerHTML, outerHTML, etc.) */
	?swap:String,

	/** CSS selector to select content from the response */
	?select:String,

	/** Values to submit with the request */
	?values:Dynamic,

	/** Headers to include with the request */
	?headers:Dynamic,
};

/** Configuration for the Htmx plugin. */
typedef HtmxConfig = {
	// Reserved for future options (e.g. custom header prefix, auto-vary)
};
