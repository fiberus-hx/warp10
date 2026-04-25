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
	 * Threshold above which send() splits the body into bounded writes.
	 * Each piece becomes a separate FD.send (yielding via io_uring), so
	 * other fibers can interleave and the kernel write buffer never has
	 * to hold the entire response at once.
	 *
	 * 256 KB is well below typical kernel socket buffer (usually ~4 MB)
	 * yet large enough that small responses still get a single write.
	 */
	public static inline var SPLIT_WRITE_THRESHOLD:Int = 256 * 1024;

	/**
	 * Send the response with the given body bytes.
	 *
	 * For small bodies (<= SPLIT_WRITE_THRESHOLD) the headers + body are
	 * concatenated and sent in one syscall.  For larger bodies the headers
	 * go out first, then the body is written in SPLIT_WRITE_THRESHOLD-sized
	 * pieces — bounds peak kernel-buffer pressure and lets other fibers
	 * make progress between pieces.
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

		var headerBytes = Bytes.ofString(buildStatusAndHeaders());

		if (body.length <= SPLIT_WRITE_THRESHOLD) {
			// Small body: combine headers and body into a single buffer for
			// one write.  Avoids an extra syscall on the common path.
			var out = Bytes.alloc(headerBytes.length + body.length);
			out.blit(0, headerBytes, 0, headerBytes.length);
			out.blit(headerBytes.length, body, 0, body.length);
			writeRaw(out);
		} else {
			// Large body: headers first, then body in bounded slices.
			if (!writeRaw(headerBytes)) return;
			var pos = 0;
			while (pos < body.length) {
				var chunkLen = body.length - pos;
				if (chunkLen > SPLIT_WRITE_THRESHOLD) chunkLen = SPLIT_WRITE_THRESHOLD;
				if (!writeRawSlice(body, pos, chunkLen)) return;
				pos += chunkLen;
			}
		}
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
		return writeRawSlice(data, 0, data.length);
	}

	/**
	 * Write a slice of bytes directly to the client socket.
	 *
	 * Like writeRaw() but takes an offset+length so callers can stream
	 * a sub-range without copying.  Loops on partial writes; returns
	 * false on error or peer disconnect.
	 */
	public function writeRawSlice(data:Bytes, offset:Int, length:Int):Bool {
		var pos = offset;
		var end = offset + length;
		while (pos < end) {
			var n = FD.send(fd, data, pos, end - pos, 0);
			if (n <= 0) {
				Sys.stderr().writeString('[WRITE-RAW] partial write: pos=$pos remaining=${end - pos} n=$n fd=$fd\n');
				Sys.stderr().flush();
				return false;
			}
			pos += n;
		}
		return true;
	}

	/**
	 * Begin a Transfer-Encoding: chunked response.
	 *
	 * Sends the status line and headers with `Transfer-Encoding: chunked`
	 * (and no Content-Length).  After this, call writeChunk() for each
	 * piece of the body and endChunked() to finish.
	 *
	 * Use when the body is built incrementally (e.g. from a database
	 * cursor) so the server doesn't have to materialize the full
	 * response in memory before any byte is sent.
	 */
	public function startChunked(?contentType:String):Bool {
		if (sent) return false;
		sent = true;
		if (contentType != null) setHeader("Content-Type", contentType);
		setHeader("Transfer-Encoding", "chunked");
		// Strip Content-Length if any plugin set it — invalid with chunked.
		var i = 0;
		while (i < headerCount) {
			if (headerKeys[i] == "Content-Length") {
				headerKeys.splice(i, 1);
				headerValues.splice(i, 1);
				headerCount--;
				continue;
			}
			i++;
		}
		ensureConnectionHeader();
		return writeRaw(Bytes.ofString(buildStatusAndHeaders()));
	}

	/**
	 * Write one HTTP chunk to a chunked-transfer-encoded response.
	 *
	 * Format: `<hex-len>\r\n<data>\r\n`.  Empty chunks are a no-op
	 * (writeChunk(emptyBytes) does NOT terminate the response — use
	 * endChunked() for that).  Returns false on peer disconnect.
	 */
	public function writeChunk(data:Bytes):Bool {
		if (data == null || data.length == 0) return true;
		var hex = StringTools.hex(data.length).toLowerCase();
		if (!writeRaw(Bytes.ofString(hex + "\r\n"))) return false;
		if (!writeRawSlice(data, 0, data.length)) return false;
		return writeRaw(Bytes.ofString("\r\n"));
	}

	/**
	 * Finish a chunked-transfer-encoded response.  Sends the
	 * terminating zero-length chunk: `0\r\n\r\n`.
	 */
	public function endChunked():Bool {
		return writeRaw(Bytes.ofString("0\r\n\r\n"));
	}

	/**
	 * Convenience: send a chunked response by invoking the producer with
	 * an emit callback.  Begins with chunked headers, calls producer to
	 * emit chunks, ends with the terminating zero-chunk.
	 *
	 * Example:
	 *   res.streamBody("application/json", emit -> {
	 *     emit(Bytes.ofString("["));
	 *     for (i in 0...rows.length) {
	 *       if (i > 0) emit(Bytes.ofString(","));
	 *       emit(Bytes.ofString(serialize(rows[i])));
	 *     }
	 *     emit(Bytes.ofString("]"));
	 *   });
	 */
	public function streamBody(?contentType:String, producer:(emit:Bytes->Bool)->Void):Void {
		if (!startChunked(contentType)) return;
		producer(function(chunk:Bytes) return writeChunk(chunk));
		endChunked();
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
