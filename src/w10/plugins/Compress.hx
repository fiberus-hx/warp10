package w10.plugins;

import haxe.io.Bytes;
import haxe.zip.FlushMode;
import w10.Context;
import w10.Response;
import w10.types.Types;
import w10.types.Hook;

/**
 * Response compression plugin for Warp10.
 *
 * Like @fastify/compress: registers an OnRequest hook that inspects the
 * Accept-Encoding request header and, if a supported encoding is found,
 * installs a body transform on the response that compresses the payload
 * before it's written to the socket.
 *
 * Supported encodings (priority order):
 *   1. deflate  -- zlib-format via haxe.zip.Compress (backed by miniz)
 *
 * Gzip and brotli are not currently supported by the fiberus runtime.
 * Deflate is universally supported by all browsers and HTTP clients.
 *
 * Usage:
 *
 *     // Global compression (register before other plugins)
 *     app.use(Compress.create({}));
 *
 *     // Or scoped
 *     app.register((scope) -> {
 *         scope.use(Compress.create({threshold: 512, level: 9}));
 *         scope.get("/big-json", handler);
 *     });
 *
 * Compression is skipped when:
 *   - Response body is below the threshold (default 1024 bytes)
 *   - Content-Type is not compressible (images, video, already-compressed)
 *   - Client does not accept any supported encoding
 *   - Request has an x-no-compression header
 *   - Compressed output is larger than original (small payloads)
 *   - Response already has a Content-Encoding header
 *
 * The plugin sets these response headers when compressing:
 *   - Content-Encoding: deflate
 *   - Vary: Accept-Encoding
 */
class Compress {
	/**
	 * Create a Compress plugin.
	 */
	public static function create(?config:CompressConfig):PluginFn {
		var cfg:CompressConfig = config != null ? config : {};
		var threshold = cfg.threshold != null ? cfg.threshold : 1024;
		var level = cfg.level != null ? cfg.level : 6;

		return (app:w10.Warp10) -> {
			app.addHook(OnRequest, (ctx:Context) -> {
				setupCompression(ctx, threshold, level);
			});
		};
	}

	/**
	 * OnRequest hook: check Accept-Encoding and install body transform.
	 */
	static function setupCompression(ctx:Context, threshold:Int, level:Int):Void {
		// Skip if client explicitly opts out
		if (ctx.getHeader("x-no-compression") != null) return;

		// Parse Accept-Encoding header
		var acceptEncoding = ctx.getHeader("accept-encoding");
		if (acceptEncoding == null) return;

		// Find the best supported encoding
		var encoding = negotiateEncoding(acceptEncoding);
		if (encoding == null) return;

		// Install the body transform on the response
		var res = ctx.res;
		res.bodyTransform = (body:Bytes) -> {
			return compressBody(res, body, encoding, threshold, level);
		};
	}

	/**
	 * Negotiate the best encoding from the Accept-Encoding header.
	 *
	 * Parses comma-separated tokens, optionally with quality values:
	 *   Accept-Encoding: gzip, deflate, br
	 *   Accept-Encoding: deflate;q=1.0, gzip;q=0.8, *;q=0.5
	 *
	 * Returns the best supported encoding name, or null if none match.
	 */
	static function negotiateEncoding(header:String):Null<String> {
		var hasDeflate = false;
		var hasStar = false;
		var identityExcluded = false;

		var tokens = header.split(",");
		for (token in tokens) {
			var trimmed = StringTools.trim(token);

			// Strip quality value (;q=0.x)
			var semiIdx = trimmed.indexOf(";");
			var name:String;
			var quality = 1.0;

			if (semiIdx >= 0) {
				name = StringTools.trim(trimmed.substring(0, semiIdx));
				var qPart = trimmed.substring(semiIdx + 1);
				var qIdx = qPart.indexOf("q=");
				if (qIdx >= 0) {
					quality = Std.parseFloat(qPart.substring(qIdx + 2));
				}
			} else {
				name = trimmed;
			}

			name = name.toLowerCase();

			// q=0 means explicitly rejected
			if (quality <= 0) {
				if (name == "identity") identityExcluded = true;
				continue;
			}

			if (name == "deflate") hasDeflate = true;
			if (name == "*") hasStar = true;
		}

		// Prefer deflate (our only supported encoding)
		if (hasDeflate) return "deflate";

		// Wildcard means "any encoding" -- use deflate
		if (hasStar) return "deflate";

		return null;
	}

	/**
	 * Compress the response body if appropriate.
	 *
	 * Returns the (possibly compressed) body bytes and sets appropriate
	 * response headers.
	 */
	static function compressBody(res:Response, body:Bytes, encoding:String, threshold:Int, level:Int):Bytes {
		// Always add Vary header so caches key on Accept-Encoding
		res.header("Vary", "Accept-Encoding");

		// Skip if already encoded
		if (res.hasHeader("Content-Encoding")) return body;

		// Skip if body is too small
		if (body.length < threshold) return body;

		// Skip if content type is not compressible
		if (!isCompressibleResponse(res)) return body;

		// Compress
		var compressed = haxe.zip.Compress.run(body, level);

		// Skip if compression didn't help (rare, but possible for small payloads)
		if (compressed.length >= body.length) return body;

		// Set encoding header
		res.header("Content-Encoding", encoding);

		return compressed;
	}

	/**
	 * Check if the response's Content-Type is compressible.
	 *
	 * Compressible types: text/*, JSON, JavaScript, XML, SVG, WASM.
	 * Not compressible: images (except SVG), audio, video, fonts,
	 * already-compressed formats (zip, gzip, br, etc.).
	 */
	static function isCompressibleResponse(res:Response):Bool {
		var ct = res.getContentType();
		if (ct == null) return true; // assume application/json if missing (like fastify)

		// Lowercase for comparison
		ct = ct.toLowerCase();

		// Strip charset and other parameters
		var semiIdx = ct.indexOf(";");
		if (semiIdx >= 0) {
			ct = ct.substring(0, semiIdx);
		}
		ct = StringTools.trim(ct);

		// text/* is always compressible
		if (StringTools.startsWith(ct, "text/")) return true;

		// Compressible application types
		if (ct == "application/json") return true;
		if (ct == "application/javascript") return true;
		if (ct == "application/x-javascript") return true;
		if (ct == "application/xml") return true;
		if (ct == "application/xhtml+xml") return true;
		if (ct == "application/x-www-form-urlencoded") return true;
		if (ct == "application/wasm") return true;
		if (ct == "application/manifest+json") return true;
		if (ct == "application/ld+json") return true;
		if (ct == "application/graphql+json") return true;
		if (ct == "application/geo+json") return true;
		if (ct == "application/vnd.api+json") return true;

		// SVG is compressible (it's XML-based)
		if (ct == "image/svg+xml") return true;

		return false;
	}
}

/** Configuration for the Compress plugin. */
typedef CompressConfig = {
	/**
	 * Minimum response body size in bytes to trigger compression.
	 * Responses smaller than this are sent uncompressed.
	 * Default: 1024
	 */
	?threshold:Int,

	/**
	 * Compression level (1-9). Higher = better compression, slower.
	 *   1 = fastest, least compression
	 *   6 = balanced (default)
	 *   9 = slowest, best compression
	 */
	?level:Int,
};
