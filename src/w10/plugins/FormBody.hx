package w10.plugins;

import w10.Context;
import w10.types.Types;
import w10.types.Hook;
import w10.utils.Http;

/**
 * Form body parser plugin for Warp10.
 *
 * Like @fastify/formbody: registers a PreHandler hook that checks if the
 * Content-Type is application/x-www-form-urlencoded, parses the body into
 * key-value pairs, and populates ctx.store["formBody"] with a
 * Map<String, String>.
 *
 * Usage:
 *
 *     // Register the plugin
 *     app.use(FormBody.create({}));
 *
 *     app.post("/submit", (ctx) -> {
 *         var name = FormBody.get(ctx, "username");
 *         var email = FormBody.get(ctx, "email");
 *         ctx.json({name: name, email: email});
 *     });
 *
 * The plugin should be registered before any plugin that reads form fields
 * (e.g. CSRF). Uses PreHandler since the body must be available and route
 * must be matched before parsing.
 */
class FormBody {
	/** Store key for the parsed form fields map */
	public static inline var STORE_KEY = "formBody";

	/**
	 * Create a FormBody plugin.
	 */
	public static function create(?config:FormBodyConfig):PluginFn {
		return (app:w10.Warp10) -> {
			app.addHook(PreHandler, (ctx:Context) -> {
				var ct = ctx.req.contentType();
				if (ct != null && ct.indexOf("application/x-www-form-urlencoded") == 0) {
					ctx.store.set(STORE_KEY, parseFormBody(ctx));
				}
			});
		};
	}

	// =========================================================================
	// Static helpers -- usable from handlers and other plugins
	// =========================================================================

	/**
	 * Get a form field value by name.
	 *
	 * Returns null if the FormBody plugin is not registered, the request
	 * is not a form submission, or the field is not present.
	 */
	public static function get(ctx:Context, name:String):Null<String> {
		var fields:Dynamic = ctx.store.get(STORE_KEY);
		if (fields == null) return null;
		var map:Map<String, String> = cast fields;
		return map.get(name);
	}

	/**
	 * Get all parsed form fields as a Map.
	 *
	 * Returns null if the FormBody plugin is not registered or the
	 * request is not a form submission.
	 */
	public static function getAll(ctx:Context):Null<Map<String, String>> {
		var fields:Dynamic = ctx.store.get(STORE_KEY);
		if (fields == null) return null;
		return cast fields;
	}

	// =========================================================================
	// Internal parsing
	// =========================================================================

	/** Parse application/x-www-form-urlencoded body into a Map */
	static function parseFormBody(ctx:Context):Map<String, String> {
		var body = ctx.req.body;
		if (body == null) return new Map<String, String>();
		return Http.parseKeyValuePairs(body.getString(0, body.length));
	}
}

/** Configuration for the FormBody plugin. */
typedef FormBodyConfig = {
	// Reserved for future options (body limit, custom parser, etc.)
};
