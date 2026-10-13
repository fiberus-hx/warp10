package w10;

import haxe.io.Bytes;
import fiberus.io.FD;
import fiberus.io.OpenFlags;
import fiberus.io.Timer;
import fiberus.Fiber;
import w10.types.Types;
import w10.types.HttpMethod;
import w10.types.HttpStatus;
import w10.types.Hook;
import w10.utils.Http;

/**
 * Core HTTP server engine for Warp10.
 *
 * Architecture (same proven model as the Fiberus HTTP benchmark):
 * - Multiple parallel accept loops with SO_REUSEPORT
 * - Kernel distributes connections across accept threads
 * - One fiber per connection via Fiber.spawn() on the accepting carrier
 * - All I/O (accept, recv, send) suspends fibers via io_uring
 * - HTTP/1.1 keep-alive by default
 *
 * The Server does not own routes -- it delegates to a Router for
 * path matching and handler dispatch.
 */
class Server {
	// GC Rework 5 Phase 5b: env-gated per-request local collection.
	// Matches BEAM fullsweep_after:0 + Bandit :erlang.garbage_collect().
	// Cached once at class-load so getenv isn't called per request.
	static final perRequestGc:Bool = Sys.getEnv("FIBERUS_PER_REQUEST_GC") == "1";

	var router:Router;
	var config:ServerConfig;
	var logger:Null<w10.utils.Logger>;

	// Resolved config values with defaults applied
	var acceptThreads:Int;
	var maxHeaderSize:Int;
	var maxBodySize:Int;
	var recvBufSize:Int;
	var keepAliveTimeout:Int;
	var maxRequestsPerConn:Int;
	var backlog:Int;

	public function new(router:Router, ?config:ServerConfig, ?logger:w10.utils.Logger) {
		this.router = router;
		this.config = config != null ? config : {};
		this.logger = logger;

		// Apply defaults
		acceptThreads = this.config.acceptThreads != null ? this.config.acceptThreads : 4;
		maxHeaderSize = this.config.maxHeaderSize != null ? this.config.maxHeaderSize : 8192;
		maxBodySize = this.config.maxBodySize != null ? this.config.maxBodySize : 256 * 1024 * 1024;
		recvBufSize = this.config.recvBufferSize != null ? this.config.recvBufferSize : 4096;
		keepAliveTimeout = this.config.keepAliveTimeout != null ? this.config.keepAliveTimeout : 15000;
		maxRequestsPerConn = this.config.maxRequestsPerConnection != null ? this.config.maxRequestsPerConnection : 1000;
		backlog = this.config.backlog != null ? this.config.backlog : 4096;
	}

	/**
	 * Start the server on the given host and port.
	 *
	 * Creates worker threads and spawns accept loops across them.
	 * Calls the callback once the server is ready to accept connections.
	 * This method blocks the calling fiber (runs the main accept loop).
	 */
	public function start(host:String, port:Int, ?onReady:Void->Void):Void {
		// Step 5 (Option B): the prior deep-promote-deep userspace bandaid was
		// removed.  Cross-thread Server/Router visibility is now maintained by
		// Step 4 codegen WBs + Step 4a runtime cross_remset (cy_wb_inline.h).
		// When worker fibers receive handler closures, the closure-arg stores
		// (closure.h capN family) feed cross_remset; cy flip drains it; Router
		// + nested route maps stay BLACK-marked across cycles.

		// Create worker threads (main thread = thread 0, workers = 1..N-1)
		if (acceptThreads > 1) {
			Fiber.createWorkers(acceptThreads - 1);
		}

		var threadCount = Fiber.getThreadCount();
		var actualAcceptThreads = acceptThreads;
		if (actualAcceptThreads > threadCount)
			actualAcceptThreads = threadCount;

		// Spawn accept loops on worker threads (1..N-1)
		var threadId = 1;
		while (threadId < actualAcceptThreads) {
			var tid = threadId;
			Fiber.spawnOn(tid, (_) -> acceptLoop(host, port, tid));
			threadId++;
		}

		// Fire the ready callback before entering the main accept loop
		if (onReady != null) {
			onReady();
		}

		// Main thread runs its own accept loop (thread 0)
		acceptLoop(host, port, 0);
	}

	/**
	 * Accept loop for a single thread.
	 *
	 * Creates its own listening socket with SO_REUSEPORT so the kernel
	 * load-balances incoming connections across all accept threads.
	 */
	function acceptLoop(host:String, port:Int, threadId:Int):Void {
		var listenFd = FD.socket(OpenFlags.AF_INET, OpenFlags.SOCK_STREAM, 0);
		if (listenFd < 0) {
			if (logger != null) logger.fatal('Thread $threadId: Failed to create socket: $listenFd');
			return;
		}

		// Allow address reuse and port sharing across threads
		FD.setsockopt(listenFd, OpenFlags.SOL_SOCKET, OpenFlags.SO_REUSEADDR, 1);
		FD.setsockopt(listenFd, OpenFlags.SOL_SOCKET, OpenFlags.SO_REUSEPORT, 1);

		var bindRes = FD.bind(listenFd, host, port);
		if (bindRes < 0) {
			if (logger != null) logger.fatal('Thread $threadId: Bind failed on $host:$port (error $bindRes)');
			FD.close(listenFd);
			return;
		}

		var listenRes = FD.listen(listenFd, backlog);
		if (listenRes < 0) {
			if (logger != null) logger.fatal('Thread $threadId: Listen failed (error $listenRes)');
			FD.close(listenFd);
			return;
		}

		// Accept loop -- each iteration suspends the fiber until a
		// connection arrives (via io_uring), then spawns a new fiber
		// to handle it.
		while (true) {
			var acceptResult = FD.accept(listenFd);
			if (acceptResult.fd < 0) {
				Timer.sleep(10);
				continue;
			}

			var clientFd = acceptResult.fd;
			var clientIp = acceptResult.host;
			var clientPort = acceptResult.port;
			acceptResult = null;  // drop GCFrame slot before spawn — prevents per-accept retention leak (see project_acceptresult_leak memory; 45 GB in 30 min soak)

			// Spawn on this carrier: SO_REUSEPORT already spreads connections across the accept loops.
			Fiber.spawn((_) -> handleConnection(clientFd, clientIp, clientPort));
		}
	}

	/**
	 * Handle a single client connection.
	 *
	 * Supports HTTP/1.1 keep-alive: loops reading requests until the
	 * client closes the connection, requests Connection: close, or
	 * the max requests per connection limit is reached.
	 *
	 * Request lifecycle (hooks are per-route, from the encapsulation scope):
	 *   1. Parse request
	 *   2. Create Context
	 *   3. Route lookup
	 *   4. If match:
	 *      a. Populate params
	 *      b. Run entry.onRequestHooks  (short-circuit if res.sent)
	 *      c. Run entry.preHandlerHooks (short-circuit if res.sent)
	 *      d. Call entry.handler
	 *      e. Ensure response sent
	 *      f. Run entry.onResponseHooks (always)
	 *   5. If no match: 404 (no hooks -- no scope to pull them from)
	 *   6. Internal request logging
	 */
	function handleConnection(clientFd:Int, clientIp:String, clientPort:Int):Void {
		// Disable Nagle's algorithm for low-latency responses
		FD.setsockopt(clientFd, OpenFlags.IPPROTO_TCP, OpenFlags.TCP_NODELAY, 1);

		var requestCount = 0;
		var conn = new ConnBuffer(maxHeaderSize);

		while (requestCount < maxRequestsPerConn) {
			// Wait for data with timeout (fiber-suspending via io_uring POLL_ADD),
			// unless a pipelined request is already buffered
			if (conn.len == 0) {
				var timeout = (requestCount == 0) ? 5000 : keepAliveTimeout;
				var pollResult = FD.poll(clientFd, OpenFlags.POLLIN, timeout);

				if (pollResult <= 0) {
					// Timeout or error
					FD.close(clientFd);
					return;
				}

				// Check for hangup/error events
				if ((pollResult & OpenFlags.POLLERR) != 0 || (pollResult & OpenFlags.POLLHUP) != 0) {
					FD.close(clientFd);
					return;
				}
			}

			// --- 1. Parse the HTTP request ---
			var req = parseRequest(clientFd, clientIp, clientPort, conn);
			if (req == null) {
				if (logger != null) {
					logger.debug("request parse failed", {ip: clientIp, statusCode: 400});
				}
				sendError(clientFd, HttpStatus.BAD_REQUEST, false);
				FD.close(clientFd);
				return;
			}

			// The last request this connection may serve says so (Connection: close), so clients
			// reconnect instead of failing their next request on a socket we are about to close.
			var keepAlive = req.isKeepAlive() && requestCount + 1 < maxRequestsPerConn;

			// --- 2. Create Context ---
			var res = new Response(clientFd);
			res.keepAlive = keepAlive;
			var ctx = new Context(req, res, logger);

			var startTime = logger != null ? w10.utils.Logger.nowMs() : 0.0;
			var handlerError:Dynamic = null;

			// --- 3. Route lookup ---
			var match = router.find(req.method, req.path);

			try {
				if (match != null) {
					var entry = match.entry;

					// --- 4a. Populate route params ---
					for (key in match.params.keys()) {
						req.params.set(key, match.params.get(key));
					}

					// Rebind the request logger with route params
					if (@:privateAccess ctx.log != null) {
						@:privateAccess ctx.log = @:privateAccess ctx.log.childWithMap({}, req.params);
					}

					// --- 4b. Run OnRequest hooks (from route's scope) ---
					runHooks(entry.onRequestHooks, ctx);

					// --- 4c. Run PreHandler hooks ---
					if (!res.sent) {
						runHooks(entry.preHandlerHooks, ctx);
					}

					// --- 4d. Call route handler ---
					if (!res.sent) {
						try {
							entry.handler(ctx);
						} catch (e:Dynamic) {
							handlerError = e;
							if (!res.sent) {
								sendError(clientFd, HttpStatus.INTERNAL_SERVER_ERROR, keepAlive);
							}
						}
					}

					// --- 4e. Ensure response sent ---
					if (!res.sent) {
						res.sendEmpty();
					}

					// --- 4f. Run OnResponse hooks (always) ---
					runHooks(entry.onResponseHooks, ctx);
				} else {
					// --- 5. No route matched -- 404 ---
					sendError(clientFd, HttpStatus.NOT_FOUND, keepAlive);
				}
			} catch (_e) {
				// --- 6. Error -- 500 ---
				sendError(clientFd, HttpStatus.INTERNAL_SERVER_ERROR, keepAlive);
			}

			// --- 6. Internal request logging ---
			if (@:privateAccess ctx.log != null) {
				var dur = Math.round((w10.utils.Logger.nowMs() - startTime) * 1000) / 1000;
				if (handlerError != null) {
					@:privateAccess ctx.log.error("request error", {statusCode: res.statusCode, responseTime: dur, err: Std.string(handlerError)});
				} else {
					@:privateAccess ctx.log.info("request completed", {statusCode: res.statusCode, responseTime: dur});
				}
			}

			// Re-read keepAlive from response -- the handler may have
			// changed it (e.g. SSE sets keepAlive=false to prevent the
			// server from trying to parse another request on the same fd).
			keepAlive = res.keepAlive;

			requestCount++;

			if (!keepAlive) {
				FD.close(clientFd);
				return;
			}

			// Phase 5b: force local collection at keepalive boundary so
			// per-request objects die before the next poll, preventing
			// cross-request accumulation in long-lived keepalive fibers.
			if (perRequestGc) {
				fiberus.GC.collect();
			}
		}

		// Exceeded max requests per connection
		FD.close(clientFd);
	}

	/**
	 * Run a chain of hook functions.
	 * Stops early if any hook sends a response (ctx.res.sent becomes true).
	 */
	function runHooks(hooks:Array<HookFn>, ctx:Context):Void {
		var i = 0;
		while (i < hooks.length) {
			hooks[i](ctx);
			if (ctx.res.sent) return;
			i++;
		}
	}

	/**
	 * Parse an HTTP request from the socket.
	 *
	 * Reads headers (up to maxHeaderSize), parses the request line and
	 * headers, then reads the body if Content-Length is present.
	 * Bytes past the request stay in `conn` for the next (pipelined) request.
	 * Returns null on parse error or connection close.
	 */
	function parseRequest(clientFd:Int, clientIp:String, clientPort:Int, conn:ConnBuffer):Null<Request> {
		// Read headers until \r\n\r\n terminator; a pipelined request may already be buffered
		var headerBuf = conn.buf;
		var totalRead = conn.len;
		var headerEnd = Http.findCrlfCrlf(headerBuf, 0, totalRead); // index where \r\n\r\n starts

		while (headerEnd < 0 && totalRead < maxHeaderSize) {
			var space = maxHeaderSize - totalRead;
			if (space <= 0)
				break;

			var n = FD.recv(clientFd, headerBuf, totalRead, space, 0);
			if (n <= 0)
				return null; // EOF or error

			totalRead += n;

			// Scan for \r\n\r\n in the newly received region
			var checkStart = totalRead - n - 3;
			if (checkStart < 0)
				checkStart = 0;

			headerEnd = Http.findCrlfCrlf(headerBuf, checkStart, totalRead);

			if (headerEnd >= 0)
				break;
		}
		conn.len = totalRead;

		if (headerEnd < 0)
			return null; // Headers too large or malformed

		// Parse the header string
		var headerStr = headerBuf.getString(0, headerEnd);
		var lines = headerStr.split("\r\n");

		if (lines.length == 0)
			return null;

		// Parse request line: "GET /path HTTP/1.1"
		var requestLine = lines[0];
		var sp1 = requestLine.indexOf(" ");
		if (sp1 == -1)
			return null;
		var sp2 = requestLine.indexOf(" ", sp1 + 1);
		if (sp2 == -1)
			return null;

		var methodStr = requestLine.substring(0, sp1);
		var fullUrl = requestLine.substring(sp1 + 1, sp2);
		var httpVersion = requestLine.substring(sp2 + 1);

		var method = HttpMethodTools.fromString(methodStr);
		if (method == null)
			return null;

		// Split URL into path and query string
		var path = fullUrl;
		var queryStr = "";
		var qIdx = fullUrl.indexOf("?");
		if (qIdx != -1) {
			path = fullUrl.substring(0, qIdx);
			queryStr = fullUrl.substring(qIdx + 1);
		}

		// Build request object
		var req = new Request();
		req.method = method;
		req.path = path;
		req.url = fullUrl;
		req.httpVersion = httpVersion;
		req.ip = clientIp;
		req.port = clientPort;

		// Parse headers (skip line 0 which is the request line)
		Http.parseHeaders(headerStr, 1, req.headers);

		// Parse query string (URL-decoded)
		if (queryStr.length > 0) {
			Http.parseKeyValuePairs(queryStr, req.query);
		}

		// Read body if Content-Length is present
		var contentLength = req.contentLength();
		var bodyStart = headerEnd + 4; // skip \r\n\r\n
		if (contentLength > 0) {
			var bodyBuf = Bytes.alloc(contentLength);
			var bodyInHeader = totalRead - bodyStart; // bytes already read past headers

			if (bodyInHeader > 0) {
				// Copy any body bytes that were already read with the headers
				var toCopy = bodyInHeader;
				if (toCopy > contentLength)
					toCopy = contentLength;
				bodyBuf.blit(0, headerBuf, bodyStart, toCopy);
				conn.consume(bodyStart + toCopy);

				// Read remaining body bytes
				var bodyRead = toCopy;
				while (bodyRead < contentLength) {
					var n = FD.recv(clientFd, bodyBuf, bodyRead, contentLength - bodyRead, 0);
					if (n <= 0)
						return null;
					bodyRead += n;
				}
			} else {
				// Read full body
				conn.consume(bodyStart);
				var bodyRead = 0;
				while (bodyRead < contentLength) {
					var n = FD.recv(clientFd, bodyBuf, bodyRead, contentLength - bodyRead, 0);
					if (n <= 0)
						return null;
					bodyRead += n;
				}
			}

			req.body = bodyBuf;
		} else {
			// Transfer-Encoding: chunked (a git push over 1 MiB, streaming clients): decode into one body
			var te = req.getHeader("transfer-encoding");
			if (te != null && te.toLowerCase().indexOf("chunked") >= 0) {
				var body = readChunkedBody(clientFd, conn, bodyStart);
				if (body == null)
					return null;
				req.body = body;
				req.headers.set("content-length", Std.string(body.length)); // handlers read one length, whatever the framing was
				req.headers.remove("transfer-encoding");
			} else {
				conn.consume(bodyStart);
			}
		}

		return req;
	}

	/**
	 * Decode a `Transfer-Encoding: chunked` request body (RFC 9112 §7.1): a hex size line per chunk, the
	 * chunk, CRLF, until a zero-size chunk; trailer lines up to an empty line are skipped. `conn` holds the
	 * bytes already received with the headers from `bodyStart`; bytes read past the body go back into it.
	 * Returns null on EOF, a malformed stream, or a body over maxBodySize (the caller closes the connection).
	 */
	function readChunkedBody(clientFd:Int, conn:ConnBuffer, bodyStart:Int):Null<Bytes> {
		var r = new ChunkedReader(clientFd, conn.len > bodyStart ? conn.buf.sub(bodyStart, conn.len - bodyStart) : Bytes.alloc(0), recvBufSize);
		conn.len = 0;
		var out = new haxe.io.BytesBuffer();
		while (true) {
			var line:Null<String> = r.readLine();
			if (line == null)
				return null;
			var semi:Int = line.indexOf(";"); // chunk extensions are ignored
			var size:Null<Int> = Std.parseInt("0x" + StringTools.trim(semi >= 0 ? line.substr(0, semi) : line));
			if (size == null || size < 0)
				return null;
			if (size == 0)
				break;
			if (out.length + size > maxBodySize)
				return null;
			if (!r.readChunk(size, out))
				return null;
		}
		while (true) {
			var trailer:Null<String> = r.readLine();
			if (trailer == null)
				return null;
			if (trailer == "")
				break;
		}
		// Bytes past the body are the next pipelined request
		var rest = r.rest();
		if (rest.length > conn.buf.length)
			return null;
		conn.buf.blit(0, rest, 0, rest.length);
		conn.len = rest.length;
		return out.getBytes();
	}

	/**
	 * Send a simple error response (for 400, 404, 500 etc.)
	 */
	function sendError(clientFd:Int, statusCode:Int, keepAlive:Bool):Void {
		var reason = HttpStatus.reason(statusCode);
		var body = '{"statusCode":$statusCode,"error":"$reason"}';

		var res = new Response(clientFd);
		res.keepAlive = keepAlive;
		res.status(statusCode).header("Content-Type", "application/json; charset=UTF-8");
		res.send(Bytes.ofString(body));
	}
}

/**
 * The byte source of a chunked request body: the unconsumed tail received with the headers, refilled
 * from the socket. Size lines and CRLFs come from the tail; a chunk's payload streams straight into the body.
 * A class, not closures: captured mutable locals are not for the fiberus target.
 */
private class ChunkedReader {
	var fd:Int;
	var data:Bytes;
	var pos:Int = 0;
	var recvSize:Int;

	public function new(fd:Int, tail:Bytes, recvSize:Int) {
		this.fd = fd;
		this.data = tail;
		this.recvSize = recvSize;
	}

	function more():Bool {
		var chunk:Bytes = Bytes.alloc(recvSize);
		var n:Int = FD.recv(fd, chunk, 0, chunk.length, 0);
		if (n <= 0)
			return false;
		var b = new haxe.io.BytesBuffer();
		b.addBytes(data, pos, data.length - pos);
		b.addBytes(chunk, 0, n);
		data = b.getBytes();
		pos = 0;
		return true;
	}

	/** The received bytes not consumed yet. */
	public function rest():Bytes
		return data.sub(pos, data.length - pos);

	/** One CRLF-terminated line, without the CRLF; null on EOF. */
	public function readLine():Null<String> {
		while (true) {
			var i:Int = pos;
			while (i + 1 < data.length && !(data.get(i) == 13 && data.get(i + 1) == 10))
				i++;
			if (i + 1 < data.length) {
				var s:String = data.getString(pos, i - pos);
				pos = i + 2;
				return s;
			}
			if (!more())
				return null;
		}
	}

	/** `size` payload bytes into `out`, then the chunk's CRLF; false on EOF or a missing CRLF. */
	public function readChunk(size:Int, out:haxe.io.BytesBuffer):Bool {
		var remaining:Int = size;
		var have:Int = data.length - pos;
		var take:Int = have < remaining ? have : remaining;
		if (take > 0) {
			out.addBytes(data, pos, take);
			pos += take;
			remaining -= take;
		}
		while (remaining > 0) {
			var buf:Bytes = Bytes.alloc(remaining < 65536 ? remaining : 65536);
			var n:Int = FD.recv(fd, buf, 0, buf.length, 0);
			if (n <= 0)
				return false;
			out.addBytes(buf, 0, n);
			remaining -= n;
		}
		while (data.length - pos < 2)
			if (!more())
				return false;
		if (!(data.get(pos) == 13 && data.get(pos + 1) == 10))
			return false;
		pos += 2;
		return true;
	}
}

/**
 * Bytes received on a connection and not consumed yet: `buf[0..len)`. Pipelined
 * requests arrive together, so what one request leaves here is the next one's start.
 */
private class ConnBuffer {
	public var buf:Bytes;
	public var len:Int = 0;

	public function new(size:Int) {
		buf = Bytes.alloc(size);
	}

	/** Drop the first `n` bytes and keep the rest. */
	public function consume(n:Int):Void {
		buf.blit(0, buf, n, len - n);
		len -= n;
	}
}
