package w10.utils;

/**
 * Pino-inspired structured JSON logger for Warp10.
 *
 * Outputs one JSON object per line to stdout with fields:
 * `level`, `time`, `msg`, and any additional data or bindings.
 *
 * Log levels use numeric values matching Pino's conventions:
 *   - Trace = 10
 *   - Debug = 20
 *   - Info  = 30  (default)
 *   - Warn  = 40
 *   - Error = 50
 *   - Fatal = 60
 *
 * Usage:
 *
 *     var log = new Logger({level: Debug, name: "myapp"});
 *     log.info("server started", {port: 3000});
 *     // {"level":30,"time":1708444800,"name":"myapp","msg":"server started","port":3000}
 *
 *     // Child loggers inherit parent bindings
 *     var reqLog = log.child({reqId: "abc123"});
 *     reqLog.info("request handled");
 *     // {"level":30,"time":...,"name":"myapp","reqId":"abc123","msg":"request handled"}
 */

/** Log level for Logger configuration */
enum LogLevel {
	Trace;
	Debug;
	Info;
	Warn;
	Error;
	Fatal;
}

/** Configuration for creating a Logger instance */
typedef LoggerConfig = {
	?level:LogLevel,
	?name:String,
};

class Logger {
	/** Numeric level threshold -- messages below this are suppressed */
	var levelThreshold:Int;

	/** Logger name (included in output if set) */
	var name:Null<String>;

	/**
	 * Pre-serialized JSON fragment for bindings.
	 * For a root logger this is empty ("").
	 * For a child logger this contains the parent's bindings + own bindings
	 * already serialized as `,"key":"value","key2":123` (leading comma included).
	 */
	var bindingsJson:String;

	/**
	 * Create a new Logger.
	 *
	 * @param config Optional configuration with level and name
	 */
	public function new(?config:LoggerConfig) {
		this.levelThreshold = config != null && config.level != null ? levelToInt(config.level) : 30;
		this.name = config != null ? config.name : null;
		this.bindingsJson = "";
	}

	/**
	 * Internal constructor for child loggers.
	 */
	function initChild(threshold:Int, name:Null<String>, bindings:String):Logger {
		var child = new Logger();
		child.levelThreshold = threshold;
		child.name = name;
		child.bindingsJson = bindings;
		return child;
	}

	// =========================================================================
	// Log methods
	// =========================================================================

	/** Log at TRACE level (10) */
	public inline function trace(msg:String, ?data:Dynamic):Void {
		if (10 >= levelThreshold)
			write(10, msg, data);
	}

	/** Log at DEBUG level (20) */
	public inline function debug(msg:String, ?data:Dynamic):Void {
		if (20 >= levelThreshold)
			write(20, msg, data);
	}

	/** Log at INFO level (30) */
	public inline function info(msg:String, ?data:Dynamic):Void {
		if (30 >= levelThreshold)
			write(30, msg, data);
	}

	/** Log at WARN level (40) */
	public inline function warn(msg:String, ?data:Dynamic):Void {
		if (40 >= levelThreshold)
			write(40, msg, data);
	}

	/** Log at ERROR level (50) */
	public inline function error(msg:String, ?data:Dynamic):Void {
		if (50 >= levelThreshold)
			write(50, msg, data);
	}

	/** Log at FATAL level (60) */
	public inline function fatal(msg:String, ?data:Dynamic):Void {
		if (60 >= levelThreshold)
			write(60, msg, data);
	}

	// =========================================================================
	// Child loggers
	// =========================================================================

	/**
	 * Create a child logger with additional bound fields.
	 *
	 * Every log entry from the child will include the parent's bindings
	 * plus the new bindings. Bindings are serialized once at creation time
	 * for zero per-log overhead.
	 *
	 *     var reqLog = log.child({reqId: "abc", ip: "127.0.0.1"});
	 *     reqLog.info("handling request");
	 *     // Output includes reqId and ip in every entry
	 */
	public function child(bindings:Dynamic):Logger {
		var extra = serializeFields(bindings);
		return initChild(levelThreshold, name, bindingsJson + extra);
	}

	/**
	 * Create a child logger with bound fields plus string map entries.
	 *
	 * Useful for including route params (Map<String, String>) alongside
	 * fixed bindings without Dynamic boxing overhead.
	 *
	 *     var reqLog = log.childWithMap({method: "GET"}, ctx.params);
	 */
	public function childWithMap(bindings:Dynamic, map:Map<String, String>):Logger {
		var extra = serializeFields(bindings);
		// Nest map entries under "params":{...} to avoid key collisions
		var hasParams = false;
		var paramsBuf = new StringBuf();
		paramsBuf.add(',"params":{');
		for (key in map.keys()) {
			if (hasParams)
				paramsBuf.add(",");
			paramsBuf.add(escapeJsonString(key));
			paramsBuf.add(":");
			paramsBuf.add(escapeJsonString(map.get(key)));
			hasParams = true;
		}
		if (hasParams) {
			paramsBuf.add("}");
			extra += paramsBuf.toString();
		}
		return initChild(levelThreshold, name, bindingsJson + extra);
	}

	// =========================================================================
	// Internal
	// =========================================================================

	/**
	 * Build and write a JSON log line to stdout.
	 */
	function write(level:Int, msg:String, data:Dynamic):Void {
		var buf = new StringBuf();
		buf.add('{"level":');
		buf.add(level);
		buf.add(',"time":');
		buf.add(epochMillis());

		if (name != null) {
			buf.add(',"name":');
			buf.add(escapeJsonString(name));
		}

		// Append pre-serialized bindings (already has leading commas)
		if (bindingsJson.length > 0) {
			buf.add(bindingsJson);
		}

		buf.add(',"msg":');
		buf.add(escapeJsonString(msg));

		// Append additional data fields
		if (data != null) {
			buf.add(serializeFields(data));
		}

		buf.add("}\n");
		Sys.print(buf.toString());
	}

	/**
	 * Serialize an anonymous object's fields as JSON key-value pairs.
	 * Returns a string like `,"key":"value","num":42` (with leading comma).
	 */
	static function serializeFields(obj:Dynamic):String {
		if (obj == null)
			return "";

		var buf = new StringBuf();
		var fields = Reflect.fields(obj);

		for (field in fields) {
			var value:Dynamic = Reflect.field(obj, field);
			buf.add(",");
			buf.add(escapeJsonString(field));
			buf.add(":");
			buf.add(serializeValue(value));
		}

		return buf.toString();
	}

	/**
	 * Serialize a single value to JSON.
	 *
	 * On fiberus (C target), Dynamic boxing doesn't reliably distinguish
	 * Int from Float -- a Float like 0.042 can pass Std.isOfType(v, Int)
	 * and get truncated. We check Bool and String first, then treat all
	 * numerics as Float and use a formatting strategy that preserves
	 * fractional values while keeping whole numbers clean.
	 */
	static function serializeValue(value:Dynamic):String {
		if (value == null)
			return "null";

		if (Std.isOfType(value, Bool)) {
			return cast(value, Bool) ? "true" : "false";
		}

		if (Std.isOfType(value, String)) {
			return escapeJsonString(cast value);
		}

		if (Std.isOfType(value, Float)) {
			var f:Float = cast value;
			// Check if it's a whole number (safe integer range)
			if (f == Math.ffloor(f) && Math.abs(f) < 1e15) {
				// Whole number -- serialize without decimals
				return Std.string(Std.int(f));
			}
			return Std.string(f);
		}

		// Fallback: use haxe.Json for complex objects/arrays
		return haxe.Json.stringify(value);
	}

	/**
	 * Escape a string for JSON output, wrapping in double quotes.
	 * Handles \, ", \n, \r, \t, and control characters.
	 */
	static function escapeJsonString(s:String):String {
		var buf = new StringBuf();
		buf.addChar('"'.code);

		var i = 0;
		while (i < s.length) {
			var c = StringTools.fastCodeAt(s, i);
			switch (c) {
				case '"'.code:
					buf.add('\\"');
				case '\\'.code:
					buf.add("\\\\");
				case '\n'.code:
					buf.add("\\n");
				case '\r'.code:
					buf.add("\\r");
				case '\t'.code:
					buf.add("\\t");
				default:
					if (c < 0x20) {
						// Control character -- \u00XX
						buf.add("\\u00");
						buf.add(StringTools.hex(c, 2));
					} else {
						buf.addChar(c);
					}
			}
			i++;
		}

		buf.addChar('"'.code);
		return buf.toString();
	}

	/**
	 * Current wall-clock time as epoch milliseconds (integer).
	 * Uses CLOCK_REALTIME via clock_gettime for millisecond precision.
	 */
	static inline function epochMillis():Float {
		return untyped __fiberus__("({ struct timespec _ts; clock_gettime(CLOCK_REALTIME, &_ts); (double)(_ts.tv_sec * 1000 + _ts.tv_nsec / 1000000); })");
	}

	/**
	 * Monotonic timestamp in milliseconds (for measuring durations).
	 * Uses CLOCK_MONOTONIC via clock_gettime for microsecond precision.
	 */
	public static inline function nowMs():Float {
		return untyped __fiberus__("({ struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts); (double)_ts.tv_sec * 1000.0 + (double)_ts.tv_nsec / 1000000.0; })");
	}

	/**
	 * Convert a LogLevel enum to its numeric value.
	 */
	static function levelToInt(level:LogLevel):Int {
		return switch (level) {
			case Trace: 10;
			case Debug: 20;
			case Info: 30;
			case Warn: 40;
			case Error: 50;
			case Fatal: 60;
		};
	}
}


