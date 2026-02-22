package w10;

import haxe.io.Bytes;
import w10.types.HttpStatus;
import w10.types.HttpMethod;

/**
 * Per-request context object passed to route handlers.
 *
 * Wraps the Request and Response, providing convenience methods
 * for the most common response patterns. This is the primary
 * interface users interact with in their handlers:
 *
 *     app.get("/hello/:name", (ctx) -> {
 *         ctx.text('Hello ${ctx.params["name"]}!');
 *     });
 *
 * The Context is intentionally lean -- cookies, form body parsing,
 * multipart, etc. are handled by plugins that store their parsed
 * data in ctx.store. See:
 *   - w10.plugins.Cookie   -- cookie parsing/setting
 *   - w10.plugins.FormBody  -- application/x-www-form-urlencoded
 *   - w10.plugins.Multipart -- multipart/form-data
 */
class Context {
	/** The parsed HTTP request */
	public var req:Request;

	/** The HTTP response builder */
	public var res:Response;

	/** Per-request child logger with method/url bindings. Null when logging is disabled. */
	public var log:Null<w10.utils.Logger>;

	/** Per-request key-value store for plugins to share data across hooks/handlers. */
	public var store:Map<String, Dynamic>;

	/** Route parameters (shortcut for req.params) */
	public var params(get, never):Map<String, String>;

	/** Query string parameters (shortcut for req.query) */
	public var query(get, never):Map<String, String>;

	/** HTTP method (shortcut for req.method) */
	public var method(get, never):HttpMethod;

	/** Request path (shortcut for req.path) */
	public var path(get, never):String;

	public function new(req:Request, res:Response, ?logger:w10.utils.Logger) {
		this.req = req;
		this.res = res;
		this.store = new Map<String, Dynamic>();
		if (logger != null) {
			this.log = logger.child({method: HttpMethodTools.toString(req.method), url: req.url});
		} else {
			this.log = null;
		}
	}

	// =========================================================================
	// Property getters (shortcuts into Request)
	// =========================================================================

	function get_params():Map<String, String>
		return req.params;

	function get_query():Map<String, String>
		return req.query;

	function get_method():HttpMethod
		return req.method;

	function get_path():String
		return req.path;

	// =========================================================================
	// Response helpers
	// =========================================================================

	/** Send a plain text response */
	public function text(body:String):Void {
		res.type("text/plain; charset=UTF-8");
		res.send(Bytes.ofString(body));
	}

	/** Send a JSON response (serializes the value with haxe.Json) */
	public function json(data:Dynamic):Void {
		res.type("application/json; charset=UTF-8");
		var jsonStr = haxe.Json.stringify(data);
		res.send(Bytes.ofString(jsonStr));
	}

	/** Send an HTML response */
	public function html(body:String):Void {
		res.type("text/html; charset=UTF-8");
		res.send(Bytes.ofString(body));
	}

	/** Send raw bytes with a given content type */
	public function bytes(data:Bytes, contentType:String):Void {
		res.type(contentType);
		res.send(data);
	}

	/** Set the response status code. Returns this for fluent chaining. */
	public function status(code:Int):Context {
		res.status(code);
		return this;
	}

	/** Set a response header. Returns this for fluent chaining. */
	public function header(key:String, value:String):Context {
		res.header(key, value);
		return this;
	}

	/** Send an HTTP redirect */
	public function redirect(url:String, ?code:Int):Void {
		res.status(code != null ? code : HttpStatus.FOUND);
		res.header("Location", url);
		res.sendEmpty();
	}

	/** Send a response with no body */
	public function sendEmpty(?code:Int):Void {
		if (code != null)
			res.status(code);
		res.sendEmpty();
	}

	/** Get a request header value (case-insensitive) */
	public function getHeader(name:String):Null<String> {
		return req.getHeader(name);
	}
}
