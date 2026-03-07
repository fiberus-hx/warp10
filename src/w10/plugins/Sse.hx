package w10.plugins;

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
	/** Store key for the SSE "closed" flag */
	static inline var CLOSED_KEY = "_sse_closed";

	/** Default heartbeat interval in milliseconds */
	static inline var DEFAULT_HEARTBEAT_MS = 15000;

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

		// Initialize closed flag
		ctx.store.set(CLOSED_KEY, false);

		// Spawn heartbeat fiber
		var heartbeatMs = DEFAULT_HEARTBEAT_MS;
		if (config != null && config.heartbeatInterval != null) {
			heartbeatMs = config.heartbeatInterval;
		}

		if (heartbeatMs > 0) {
			spawnHeartbeat(ctx, heartbeatMs);
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
	 * (client disconnect). Also checks the internal closed flag.
	 *
	 * @param ctx  The request context
	 * @return true if the client is still connected
	 */
	public static function isConnected(ctx:Context):Bool {
		// Check closed flag
		var closed:Dynamic = ctx.store.get(CLOSED_KEY);
		if (closed == true) return false;

		// Non-blocking poll for disconnect events
		var pollResult = FD.poll(ctx.res.fd, OpenFlags.POLLERR | OpenFlags.POLLHUP, 0);

		// pollResult > 0 means events were detected (error/hangup)
		if (pollResult > 0) {
			if ((pollResult & OpenFlags.POLLERR) != 0 || (pollResult & OpenFlags.POLLHUP) != 0) {
				ctx.store.set(CLOSED_KEY, true);
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
	 * Sets the closed flag so the heartbeat fiber stops. The connection
	 * itself is closed by Server.hx when the handler returns (since
	 * keepAlive was set to false by start()).
	 *
	 * @param ctx  The request context
	 */
	public static function close(ctx:Context):Void {
		ctx.store.set(CLOSED_KEY, true);
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
	 */
	static function spawnHeartbeat(ctx:Context, intervalMs:Int):Void {
		Fiber.spawnAny((_) -> {
			while (true) {
				Timer.sleep(intervalMs);

				// Check if stream was closed
				var closed:Dynamic = ctx.store.get(CLOSED_KEY);
				if (closed == true) return;

				// Send heartbeat comment
				var ok = ctx.res.writeRaw(Bytes.ofString(":\n\n"));
				if (!ok) {
					// Write failed -- client disconnected
					ctx.store.set(CLOSED_KEY, true);
					return;
				}
			}
		});
	}
}

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
