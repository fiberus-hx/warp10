package w10.plugins;

import haxe.atomic.AtomicBool;
import haxe.io.Bytes;
import fiberus.io.FD;
import fiberus.io.OpenFlags;
import fiberus.io.Timer;
import fiberus.Fiber;
import w10.Context;

/**
 * Server-Sent Events (SSE) helper for Warp10.
 *
 * Inspired by @fastify/sse. Provides static methods for streaming
 * SSE events from route handlers. Uses Warp10's fiber-per-connection
 * model -- the handler fiber blocks while streaming, and a background
 * heartbeat fiber keeps the connection alive through proxies.
 *
 * Thread safety:
 *
 *   The handler fiber and the heartbeat fiber may run on different OS
 *   threads (heartbeat is spawned via Fiber.spawnAny). All shared state
 *   between the two fibers uses AtomicBool for synchronization. The
 *   close() method waits for the heartbeat fiber to exit before
 *   returning, ensuring the fd is not used after Server.hx closes it.
 *
 * SSE wire format (WHATWG spec):
 *   - `data:` lines carry the event payload (multiple lines joined with \n)
 *   - `event:` sets the event type (default "message")
 *   - `id:` sets the last event ID (persisted across reconnects)
 *   - `retry:` sets the reconnection interval in milliseconds
 *   - `:` comment lines serve as keep-alive pings
 *   - Events are terminated by a blank line (\n\n)
 *
 * Usage (manual loop):
 *
 *     app.get("/events", (ctx) -> {
 *         Sse.start(ctx);
 *         var id = 0;
 *         while (Sse.isConnected(ctx)) {
 *             Sse.sendJson(ctx, {count: id}, "tick", Std.string(id));
 *             id++;
 *             Timer.sleep(1000);
 *         }
 *         Sse.close(ctx);
 *     });
 *
 * Usage (managed stream):
 *
 *     app.get("/events", (ctx) -> {
 *         Sse.stream(ctx, null, (send) -> {
 *             var id = 0;
 *             while (send({data: Std.string(id), event: "tick", id: Std.string(id)})) {
 *                 id++;
 *                 Timer.sleep(1000);
 *             }
 *         });
 *     });
 *
 * Client-side:
 *
 *     const es = new EventSource("/events");
 *     es.addEventListener("tick", (e) => console.log(e.data));
 *
 * Test with curl:
 *
 *     curl -N http://localhost:8080/events
 */
class Sse {
	/** Store key for the SSE state (SseState reference) */
	static inline var STATE_KEY = "_sse_state";

	/** Default heartbeat interval in milliseconds */
	static inline var DEFAULT_HEARTBEAT_MS = 15000;

	/**
	 * Granularity for heartbeat sleep.
	 *
	 * The heartbeat fiber sleeps in chunks of this duration,
	 * checking the closed flag between chunks. This bounds
	 * the maximum time close() has to wait for the heartbeat
	 * to notice the shutdown signal.
	 */
	static inline var HEARTBEAT_POLL_MS = 500;

	// =========================================================================
	// Core API
	// =========================================================================

	/**
	 * Start an SSE stream.
	 *
	 * Sets the required SSE response headers (Content-Type, Cache-Control,
	 * Connection, X-Accel-Buffering), sends them to the client, marks the
	 * connection as non-keep-alive (so Server.hx closes the fd when the
	 * handler returns), and spawns a background heartbeat fiber.
	 *
	 * Must be called before any send*() calls.
	 *
	 * @param ctx     The request context
	 * @param config  Optional configuration (heartbeat interval)
	 */
	public static function start(ctx:Context, ?config:SseConfig):Void {
		// Set SSE headers
		ctx.res.status(200);
		ctx.res.header("Content-Type", "text/event-stream");
		ctx.res.header("Cache-Control", "no-cache");
		ctx.res.header("Connection", "keep-alive");
		ctx.res.header("X-Accel-Buffering", "no");

		// Prevent the server from trying to reuse this connection
		// for another HTTP request after the handler returns
		ctx.res.keepAlive = false;

		// Send headers (no Content-Length, no body)
		ctx.res.sendHeaders();

		// Create shared state with atomic flags for thread-safe
		// communication between handler fiber and heartbeat fiber.
		// This is stored in ctx.store ONCE here (before the heartbeat
		// is spawned), then only read out of the store -- never written
		// back. All subsequent state changes go through the AtomicBools.
		var state:SseState = {
			closed: new AtomicBool(false),
			heartbeatExited: new AtomicBool(true), // true = no heartbeat running
		};
		ctx.store.set(STATE_KEY, state);

		// Spawn heartbeat fiber
		var heartbeatMs = DEFAULT_HEARTBEAT_MS;
		if (config != null && config.heartbeatInterval != null) {
			heartbeatMs = config.heartbeatInterval;
		}

		if (heartbeatMs > 0) {
			state.heartbeatExited.store(false);
			spawnHeartbeat(ctx.res.fd, state, heartbeatMs);
		}
	}

	/**
	 * Send a full SSE message.
	 *
	 * Formats the message according to the SSE wire protocol and writes
	 * it to the client socket. Returns false if the write failed (client
	 * disconnected).
	 *
	 * @param ctx  The request context
	 * @param msg  The SSE message to send
	 * @return true if sent successfully, false if disconnected
	 */
	public static function send(ctx:Context, msg:SseMessage):Bool {
		var frame = formatMessage(msg);
		return ctx.res.writeRaw(Bytes.ofString(frame));
	}

	/**
	 * Send a text data event.
	 *
	 * Convenience wrapper around send() for simple text payloads.
	 *
	 * @param ctx    The request context
	 * @param data   The text payload
	 * @param event  Optional event type (default: "message")
	 * @param id     Optional event ID
	 * @return true if sent successfully, false if disconnected
	 */
	public static function sendData(ctx:Context, data:String, ?event:String, ?id:String):Bool {
		return send(ctx, {data: data, event: event, id: id});
	}

	/**
	 * Send a JSON-serialized data event.
	 *
	 * Serializes the value with haxe.Json.stringify() and sends it
	 * as an SSE data event. Objects are serialized to a single line.
	 *
	 * @param ctx    The request context
	 * @param data   The value to JSON-serialize
	 * @param event  Optional event type (default: "message")
	 * @param id     Optional event ID
	 * @return true if sent successfully, false if disconnected
	 */
	public static function sendJson(ctx:Context, data:Dynamic, ?event:String, ?id:String):Bool {
		var jsonStr = haxe.Json.stringify(data);
		return send(ctx, {data: jsonStr, event: event, id: id});
	}

	/**
	 * Send a comment line (keep-alive ping).
	 *
	 * Comments start with `:` and are ignored by the EventSource client.
	 * They keep the connection alive through proxies and load balancers.
	 *
	 * @param ctx   The request context
	 * @param text  Optional comment text (default: empty)
	 * @return true if sent successfully, false if disconnected
	 */
	public static function sendComment(ctx:Context, ?text:String):Bool {
		var frame = (text != null) ? ': $text\n\n' : ':\n\n';
		return ctx.res.writeRaw(Bytes.ofString(frame));
	}

	/**
	 * Send a retry directive.
	 *
	 * Tells the client to wait `ms` milliseconds before reconnecting
	 * if the connection is lost.
	 *
	 * @param ctx  The request context
	 * @param ms   Reconnection interval in milliseconds
	 * @return true if sent successfully, false if disconnected
	 */
	public static function sendRetry(ctx:Context, ms:Int):Bool {
		var frame = 'retry: ${Std.string(ms)}\n\n';
		return ctx.res.writeRaw(Bytes.ofString(frame));
	}

	/**
	 * Check if the client is still connected.
	 *
	 * Performs a non-blocking poll on the socket to detect POLLERR/POLLHUP
	 * (client disconnect). Also checks the atomic closed flag.
	 *
	 * @param ctx  The request context
	 * @return true if the client is still connected
	 */
	public static function isConnected(ctx:Context):Bool {
		var state = getState(ctx);
		if (state == null) return false;

		// Check closed flag (atomic)
		if (state.closed.load()) return false;

		// Non-blocking poll for disconnect events
		var pollResult = FD.poll(ctx.res.fd, OpenFlags.POLLERR | OpenFlags.POLLHUP, 0);

		// pollResult > 0 means events were detected (error/hangup)
		if (pollResult > 0) {
			if ((pollResult & OpenFlags.POLLERR) != 0 || (pollResult & OpenFlags.POLLHUP) != 0) {
				state.closed.store(true);
				return false;
			}
		}

		return true;
	}

	/**
	 * Get the Last-Event-ID from the request.
	 *
	 * When a client reconnects after a disconnect, the EventSource API
	 * sends the last received event ID in the `Last-Event-ID` header.
	 * Use this to replay missed events.
	 *
	 * @param ctx  The request context
	 * @return The last event ID, or null if not present
	 */
	public static function getLastEventId(ctx:Context):Null<String> {
		return ctx.getHeader("last-event-id");
	}

	/**
	 * Close the SSE stream.
	 *
	 * Sets the closed flag atomically, then waits for the heartbeat
	 * fiber to exit before returning. This is critical: Server.hx
	 * closes the fd immediately after the handler returns, so the
	 * heartbeat must have stopped writing to the fd by that point.
	 *
	 * The heartbeat fiber checks the closed flag in HEARTBEAT_POLL_MS
	 * intervals (500ms), so the maximum wait is one poll interval plus
	 * the time for any in-flight writeRaw to complete.
	 *
	 * @param ctx  The request context
	 */
	public static function close(ctx:Context):Void {
		var state = getState(ctx);
		if (state == null) return;

		// Signal the heartbeat to stop (atomic)
		state.closed.store(true);

		// Wait for heartbeat fiber to exit.
		// The heartbeat sleeps in HEARTBEAT_POLL_MS chunks and checks
		// the closed flag between chunks, so worst case we wait ~500ms
		// plus any in-flight io_uring send completion.
		while (!state.heartbeatExited.load()) {
			Timer.sleep(10);
		}
	}

	// =========================================================================
	// Managed stream API
	// =========================================================================

	/**
	 * Run a managed SSE stream.
	 *
	 * Calls start(), invokes the callback with a send function, and
	 * ensures close() is called when the callback returns or throws.
	 * The callback receives a `send` function that formats and writes
	 * SSE messages -- it returns false when the client disconnects,
	 * signaling the callback to stop.
	 *
	 * Usage:
	 *
	 *     Sse.stream(ctx, null, (send) -> {
	 *         var n = 0;
	 *         while (send({data: Std.string(n), id: Std.string(n)})) {
	 *             n++;
	 *             Timer.sleep(1000);
	 *         }
	 *     });
	 *
	 * @param ctx       The request context
	 * @param config    Optional SSE configuration
	 * @param callback  The streaming function. Receives a send function
	 *                  that returns false on disconnect.
	 */
	public static function stream(ctx:Context, ?config:SseConfig, callback:SseStreamCallback):Void {
		start(ctx, config);

		try {
			callback((msg:SseMessage) -> {
				return send(ctx, msg);
			});
		} catch (e:Dynamic) {
			ctx.error("SSE stream error", {err: Std.string(e)});
		}

		close(ctx);
	}

	// =========================================================================
	// Internal helpers
	// =========================================================================

	/**
	 * Retrieve the SseState from ctx.store.
	 *
	 * The state is stored once by start() and never overwritten. This
	 * read-only Map access is safe even from the heartbeat fiber because
	 * no concurrent writes to the Map occur after start() returns.
	 */
	static function getState(ctx:Context):Null<SseState> {
		var s:Dynamic = ctx.store.get(STATE_KEY);
		if (s == null) return null;
		return cast s;
	}

	/**
	 * Format an SSE message according to the wire protocol.
	 *
	 * Produces a string like:
	 *   id: 42\nevent: update\ndata: {"temp":22}\n\n
	 *
	 * Multi-line data is split into multiple `data:` lines per the spec.
	 */
	static function formatMessage(msg:SseMessage):String {
		var buf = new StringBuf();

		if (msg.id != null) {
			buf.add("id: ");
			buf.add(msg.id);
			buf.add("\n");
		}

		if (msg.event != null) {
			buf.add("event: ");
			buf.add(msg.event);
			buf.add("\n");
		}

		if (msg.retry != null) {
			buf.add("retry: ");
			buf.add(Std.string(msg.retry));
			buf.add("\n");
		}

		// Data field -- split on newlines per the SSE spec
		// (each line becomes a separate `data:` line)
		var dataLines = msg.data.split("\n");
		for (line in dataLines) {
			buf.add("data: ");
			buf.add(line);
			buf.add("\n");
		}

		// Blank line terminates the event
		buf.add("\n");

		return buf.toString();
	}

	/**
	 * Spawn a background heartbeat fiber.
	 *
	 * Sends `:` comment lines at the configured interval to keep the
	 * connection alive through proxies. Stops when the closed flag
	 * is set or a write fails.
	 *
	 * The heartbeat sleeps in small chunks (HEARTBEAT_POLL_MS) and
	 * checks the closed flag between chunks. This ensures the
	 * heartbeat exits promptly when close() is called, bounding
	 * the time close() has to wait.
	 *
	 * Takes the fd and state directly (not ctx) to avoid any
	 * ctx.store access from the heartbeat fiber.
	 */
	static function spawnHeartbeat(fd:Int, state:SseState, intervalMs:Int):Void {
		Fiber.spawnAny((_) -> {
			var heartbeatBytes = Bytes.ofString(":\n\n");

			while (true) {
				// Sleep in small chunks, checking closed flag between each
				var elapsed = 0;
				while (elapsed < intervalMs) {
					var chunk = intervalMs - elapsed;
					if (chunk > HEARTBEAT_POLL_MS) chunk = HEARTBEAT_POLL_MS;
					Timer.sleep(chunk);
					elapsed += chunk;

					// Check if stream was closed (atomic)
					if (state.closed.load()) {
						state.heartbeatExited.store(true);
						return;
					}
				}

				// Send heartbeat comment
				var ok = FD.send(fd, heartbeatBytes, 0, heartbeatBytes.length, 0) > 0;
				if (!ok) {
					// Write failed -- client disconnected
					state.closed.store(true);
					state.heartbeatExited.store(true);
					return;
				}
			}
		});
	}
}

// =============================================================================
// Internal types
// =============================================================================

/**
 * Shared state between handler fiber and heartbeat fiber.
 *
 * All fields are AtomicBool for thread-safe access. This struct
 * is stored in ctx.store once by start() and only read out (never
 * written back). All state mutations go through the atomic operations.
 */
private typedef SseState = {
	/** Set to true when the stream should close.
	 *  Written by close() or heartbeat (on write failure).
	 *  Read by heartbeat (to know when to stop) and isConnected(). */
	closed:AtomicBool,

	/** Set to true when the heartbeat fiber has exited.
	 *  Written by heartbeat (on exit). Read by close() (to wait). */
	heartbeatExited:AtomicBool,
};

// =============================================================================
// Configuration typedefs
// =============================================================================

/** An SSE message to send to the client. */
typedef SseMessage = {
	/** The event payload (required). Multi-line strings are supported. */
	data:String,

	/** Named event type. If omitted, the client receives it as "message".
	 *  Client listens via eventSource.addEventListener("eventName", ...). */
	?event:String,

	/** Event ID. Persisted by the client and sent back as Last-Event-ID
	 *  on reconnection. */
	?id:String,

	/** Reconnection interval in milliseconds. Tells the client how long
	 *  to wait before reconnecting if the connection drops. */
	?retry:Int,
};

/** Configuration for the SSE stream. */
typedef SseConfig = {
	/** Heartbeat interval in milliseconds. A comment line (`:`) is sent
	 *  at this interval to keep the connection alive through proxies.
	 *  Set to 0 to disable heartbeat. Default: 15000 (15 seconds). */
	?heartbeatInterval:Int,
};

/** Callback function for Sse.stream(). Receives a send function that
 *  returns false when the client disconnects. */
typedef SseStreamCallback = (send:(msg:SseMessage) -> Bool) -> Void;
