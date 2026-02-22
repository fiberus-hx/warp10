package w10;

import haxe.io.Bytes;
import w10.types.HttpMethod;

/**
 * Represents a parsed HTTP request.
 *
 * Populated by the Server during HTTP parsing. Route params are
 * added by the Router after path matching.
 */
class Request {
	/** HTTP method (GET, POST, etc.) */
	public var method:HttpMethod;

	/** URL path without query string (e.g. "/users/42") */
	public var path:String;

	/** Full request URL including query string (e.g. "/users/42?verbose=true") */
	public var url:String;

	/** HTTP version string (e.g. "HTTP/1.1") */
	public var httpVersion:String;

	/** Request headers (lowercase keys) */
	public var headers:Map<String, String>;

	/** Route parameters populated by the router (e.g. {id: "42"}) */
	public var params:Map<String, String>;

	/** Parsed query string parameters */
	public var query:Map<String, String>;

	/** Raw request body bytes (null if no body) */
	public var body:Null<Bytes>;

	/** Client IP address */
	public var ip:String;

	/** Client port */
	public var port:Int;

	public function new() {
		method = Get;
		path = "/";
		url = "/";
		httpVersion = "HTTP/1.1";
		headers = new Map<String, String>();
		params = new Map<String, String>();
		query = new Map<String, String>();
		body = null;
		ip = "";
		port = 0;
	}

	/** Get a header value by name (case-insensitive lookup, headers stored lowercase) */
	public function getHeader(name:String):Null<String> {
		return headers.get(name.toLowerCase());
	}

	/** Returns the Content-Type header value, or null */
	public function contentType():Null<String> {
		return headers.get("content-type");
	}

	/** Returns the Content-Length as an Int, or -1 if not present */
	public function contentLength():Int {
		var cl = headers.get("content-length");
		if (cl == null)
			return -1;
		var parsed = Std.parseInt(cl);
		return parsed != null ? parsed : -1;
	}

	/** Returns true if the client requested Connection: close */
	public function wantsClose():Bool {
		var conn = headers.get("connection");
		return conn != null && conn == "close";
	}

	/** Returns true if this is a keep-alive connection (HTTP/1.1 default) */
	public function isKeepAlive():Bool {
		return !wantsClose();
	}
}
