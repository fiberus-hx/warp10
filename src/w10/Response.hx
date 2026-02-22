package w10;

import haxe.io.Bytes;
import w10.types.HttpStatus;
import fiberus.io.FD;

/**
 * HTTP response builder and sender.
 *
 * Accumulates status, headers, and body, then flushes everything
 * to the client socket in a single write. Uses FD.send() which
 * suspends the fiber (not the thread) on io_uring.
 *
 * Headers are stored as a flat array of key-value pairs [k1, v1, k2, v2, ...]
 * to avoid Map overhead and dynamic iteration patterns.
 */
class Response {
	/** HTTP status code (default 200) */
	public var statusCode:Int;

	/** Whether the response has already been sent */
	public var sent(default, null):Bool;

	/** The client socket file descriptor (public for streaming responses like SSE) */
	public var fd:Int;

	/** Whether keep-alive is enabled for this response */
	public var keepAlive:Bool;

	/**
	 * Optional body transform applied by send() before writing to the socket.
	 *
	 * Set by plugins like Compress to intercept and transform the response
	 * body (e.g. compression) before Content-Length is calculated and the
	 * response is flushed. The transform receives the original body bytes
	 * and must return the (possibly modified) bytes.
	 *
	 * Only one transform is supported. If multiple plugins need to transform
	 * the body, they should chain by wrapping the previous transform.
	 */
	public var bodyTransform:Null<Bytes->Bytes>;

	/** Headers stored as flat array: [key1, val1, key2, val2, ...] */
	var headerKeys:Array<String>;

	var headerValues:Array<String>;
	var headerCount:Int;

	public function new(fd:Int) {
		this.fd = fd;
		this.statusCode = HttpStatus.OK;
		this.sent = false;
		this.keepAlive = true;
		this.headerKeys = new Array<String>();
		this.headerValues = new Array<String>();
		this.headerCount = 0;

		// Default headers
		setHeader("Server", "Warp10");
	}

	/** Set the HTTP status code. Returns this for fluent chaining. */
	public function status(code:Int):Response {
		statusCode = code;
		return this;
	}

	/** Set a response header. Overwrites if already present. Returns this for fluent chaining. */
	public function header(key:String, value:String):Response {
		setHeader(key, value);
		return this;
	}

	/** Set the Content-Type header. Returns this for fluent chaining. */
	public function type(contentType:String):Response {
		setHeader("Content-Type", contentType);
		return this;
	}

	/**
	 * Append a header without overwriting existing ones.
	 *
	 * Unlike header()/setHeader(), this always adds a new entry even
	 * if a header with the same key already exists. Required for headers
	 * like Set-Cookie where multiple values must be sent as separate
	 * headers (not comma-joined per HTTP spec).
	 *
	 * Returns this for fluent chaining.
	 */
	public function addHeader(key:String, value:String):Response {
		headerKeys.push(key);
		headerValues.push(value);
		headerCount++;
		return this;
	}

	/** Internal: set or overwrite a header */
	function setHeader(key:String, value:String):Void {
		// Check if header already exists
		var i = 0;
		while (i < headerCount) {
			if (headerKeys[i] == key) {
				headerValues[i] = value;
				return;
			}
			i++;
		}
		// Add new header
		headerKeys.push(key);
		headerValues.push(value);
		headerCount++;
	}

	/** Check if a header exists */
	public function hasHeader(key:String):Bool {
		var i = 0;
		while (i < headerCount) {
			if (headerKeys[i] == key)
				return true;
			i++;
		}
		return false;
	}

	/** Get the value of a response header, or null if not set */
	public function getHeader(key:String):Null<String> {
		var i = 0;
		while (i < headerCount) {
			if (headerKeys[i] == key)
				return headerValues[i];
			i++;
		}
		return null;
	}

	/** Get the Content-Type header value, or null if not set */
	public function getContentType():Null<String> {
		return getHeader("Content-Type");
	}

	/**
	 * Send the response with the given body bytes.
	 * Serializes status line + headers + body and writes to the socket.
	 */
	public function send(body:Bytes):Void {
		if (sent)
			return;
		sent = true;

		// Apply body transform (e.g. compression) before Content-Length
		if (bodyTransform != null) {
			body = bodyTransform(body);
		}

		// Set Content-Length if not already set
		if (!hasHeader("Content-Length")) {
			setHeader("Content-Length", Std.string(body.length));
		}

		ensureConnectionHeader();

		// Build the full HTTP response as a single string
		var resp = buildStatusAndHeaders();

		// Combine headers and body into a single buffer for one write
		var headerBytes = Bytes.ofString(resp);
		var total = headerBytes.length + body.length;
		var out = Bytes.alloc(total);
		out.blit(0, headerBytes, 0, headerBytes.length);
		out.blit(headerBytes.length, body, 0, body.length);

		// Write to socket (fiber-suspending via io_uring)
		writeRaw(out);
	}

	/**
	 * Send a response with no body (e.g. 204 No Content, 304 Not Modified).
	 */
	public function sendEmpty():Void {
		if (sent)
			return;
		sent = true;

		setHeader("Content-Length", "0");
		ensureConnectionHeader();

		writeRaw(Bytes.ofString(buildStatusAndHeaders()));
	}

	/**
	 * Send only the status line and headers (no body, no Content-Length).
	 *
	 * For streaming responses (SSE, chunked transfers) where the body
	 * will be written incrementally via writeRaw(). Sets sent=true so
	 * the server won't call sendEmpty(). Does NOT set Content-Length,
	 * allowing the connection to remain open for streaming.
	 */
	public function sendHeaders():Void {
		if (sent)
			return;
		sent = true;

		ensureConnectionHeader();

		writeRaw(Bytes.ofString(buildStatusAndHeaders()));
	}

	/**
	 * Write raw bytes directly to the client socket.
	 *
	 * For use after sendHeaders() to stream data incrementally.
	 * Returns true on success, false if the write failed (client
	 * disconnected or socket error). Each call is a single io_uring
	 * SQE -- safe for concurrent use from separate fibers as long
	 * as each write is a complete logical frame.
	 */
	public function writeRaw(data:Bytes):Bool {
		var pos = 0;
		while (pos < data.length) {
			var n = FD.send(fd, data, pos, data.length - pos, 0);
			if (n <= 0)
				return false;
			pos += n;
		}
		return true;
	}

	/** Set the Connection header based on keep-alive if not already set */
	function ensureConnectionHeader():Void {
		if (!hasHeader("Connection")) {
			setHeader("Connection", keepAlive ? "keep-alive" : "close");
		}
	}

	/** Build the status line and headers as a string */
	function buildStatusAndHeaders():String {
		var s = 'HTTP/1.1 ${Std.string(statusCode)} ${HttpStatus.reason(statusCode)}\r\n';

		var i = 0;
		while (i < headerCount) {
			s = s + headerKeys[i] + ": " + headerValues[i] + "\r\n";
			i++;
		}

		s = s + "\r\n";
		return s;
	}
}
