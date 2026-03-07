package w10.plugins;

import haxe.io.Bytes;
import w10.Context;
import w10.types.Types;
import w10.types.Hook;
import w10.utils.Http;

/**
 * Multipart form-data parser plugin for Warp10.
 *
 * Like @fastify/multipart: registers a PreHandler hook that checks if the
 * Content-Type is multipart/form-data, parses the boundary-delimited body
 * into parts, and populates ctx.store with:
 *
 *   - "multiparts"  -> Array<MultipartPart>  (all parts, including files)
 *   - "formBody"    -> Map<String, String>    (text fields merged, same key
 *                      as FormBody plugin so CSRF etc. work transparently)
 *
 * Usage:
 *
 *     app.use(Multipart.create({limits: {fileSize: 5 * 1024 * 1024}}));
 *
 *     app.post("/upload", (ctx) -> {
 *         var parts = Multipart.getParts(ctx);
 *         if (parts != null) {
 *             for (part in parts) {
 *                 if (part.filename != null) {
 *                     // file upload: part.data contains the bytes
 *                     ctx.info("uploaded file", {
 *                         name: part.filename,
 *                         size: part.data.length,
 *                         type: part.contentType
 *                     });
 *                 }
 *             }
 *         }
 *         ctx.json({ok: true});
 *     });
 *
 * Note: This is a buffer-based parser (entire body in memory). For V1 this
 * is fine since Fiberus doesn't have streaming body support yet. The body
 * is already fully read by Server.parseRequest() into req.body.
 */
class Multipart {
	/** Store key for the parsed parts array */
	public static inline var STORE_KEY = "multiparts";

	/**
	 * Create a Multipart plugin.
	 */
	public static function create(?config:MultipartConfig):PluginFn {
		var cfg:MultipartConfig = config != null ? config : {};

		// Resolve limits with defaults
		var maxFileSize = 1048576; // 1MB
		var maxFiles = 10;
		var maxFields = 100;
		var maxFieldSize = 1048576; // 1MB

		if (cfg.limits != null) {
			if (cfg.limits.fileSize != null) maxFileSize = cfg.limits.fileSize;
			if (cfg.limits.files != null) maxFiles = cfg.limits.files;
			if (cfg.limits.fields != null) maxFields = cfg.limits.fields;
			if (cfg.limits.fieldSize != null) maxFieldSize = cfg.limits.fieldSize;
		}

		return (app:w10.Warp10) -> {
			app.addHook(PreHandler, (ctx:Context) -> {
				var ct = ctx.req.contentType();
				if (ct != null && ct.indexOf("multipart/form-data") == 0) {
					parseMultipart(ctx, ct, maxFileSize, maxFiles, maxFields, maxFieldSize);
				}
			});
		};
	}

	// =========================================================================
	// Static helpers
	// =========================================================================

	/**
	 * Get all parsed multipart parts.
	 *
	 * Returns null if the Multipart plugin is not registered or the
	 * request is not multipart/form-data.
	 */
	public static function getParts(ctx:Context):Null<Array<MultipartPart>> {
		var parts:Dynamic = ctx.store.get(STORE_KEY);
		if (parts == null) return null;
		return cast parts;
	}

	/**
	 * Get the first file part with the given field name.
	 *
	 * Returns null if not found.
	 */
	public static function getFile(ctx:Context, fieldname:String):Null<MultipartPart> {
		var parts = getParts(ctx);
		if (parts == null) return null;
		for (part in parts) {
			if (part.fieldname == fieldname && part.filename != null) return part;
		}
		return null;
	}

	// =========================================================================
	// Multipart boundary parser
	// =========================================================================

	/**
	 * Parse multipart/form-data body.
	 *
	 * Multipart format:
	 *   --boundary\r\n
	 *   Content-Disposition: form-data; name="field"; filename="file.txt"\r\n
	 *   Content-Type: text/plain\r\n
	 *   \r\n
	 *   <part body>\r\n
	 *   --boundary\r\n
	 *   ...
	 *   --boundary--\r\n
	 */
	static function parseMultipart(
		ctx:Context,
		contentType:String,
		maxFileSize:Int,
		maxFiles:Int,
		maxFields:Int,
		maxFieldSize:Int
	):Void {
		var body = ctx.req.body;
		if (body == null) return;

		// Extract boundary from Content-Type header
		var boundary = extractBoundary(contentType);
		if (boundary == null) return;

		var parts = new Array<MultipartPart>();
		var formFields = new Map<String, String>();
		var fileCount = 0;
		var fieldCount = 0;

		// The delimiter is "--" + boundary
		var delimiter = Bytes.ofString("--" + boundary);
		var delimLen = delimiter.length;
		var bodyLen = body.length;

		// Find the first delimiter
		var pos = Http.findBytes(body, delimiter, 0);
		if (pos < 0) return;

		// Skip past first delimiter + \r\n
		pos = pos + delimLen;
		if (pos + 2 <= bodyLen && body.get(pos) == 13 && body.get(pos + 1) == 10) {
			pos += 2;
		}

		// Parse each part
		while (pos < bodyLen) {
			// Check for closing delimiter "--boundary--"
			if (pos + 2 <= bodyLen && body.get(pos) == 45 && body.get(pos + 1) == 45) {
				break; // End of multipart
			}

			// Find the end of headers (double \r\n)
			var headerEnd = Http.findCrlfCrlf(body, pos);
			if (headerEnd < 0) break;

			// Parse part headers
			var headerStr = body.getString(pos, headerEnd - pos);
			var partHeaders = Http.parseHeaders(headerStr);

			// Extract Content-Disposition fields
			var disposition = partHeaders.get("content-disposition");
			if (disposition == null) {
				// Skip malformed part
				pos = Http.findBytes(body, delimiter, headerEnd + 4);
				if (pos < 0) break;
				pos = pos + delimLen + 2; // skip delimiter + \r\n
				continue;
			}

			var fieldname = extractDispositionParam(disposition, "name");
			var filename = extractDispositionParam(disposition, "filename");
			var partContentType = partHeaders.get("content-type");

			// Body starts after \r\n\r\n
			var bodyStart = headerEnd + 4;

			// Find the next delimiter to determine body end
			var nextDelim = Http.findBytes(body, delimiter, bodyStart);
			if (nextDelim < 0) break;

			// Body ends 2 bytes before the delimiter (\r\n before --boundary)
			var bodyEnd = nextDelim - 2;
			if (bodyEnd < bodyStart) bodyEnd = bodyStart;

			var partBodyLen = bodyEnd - bodyStart;

			// Enforce limits
			if (filename != null) {
				fileCount++;
				if (fileCount > maxFiles) break;
				if (partBodyLen > maxFileSize) break;
			} else {
				fieldCount++;
				if (fieldCount > maxFields) break;
				if (partBodyLen > maxFieldSize) break;
			}

			// Extract part body
			var partData = Bytes.alloc(partBodyLen);
			if (partBodyLen > 0) {
				partData.blit(0, body, bodyStart, partBodyLen);
			}

			var part:MultipartPart = {
				fieldname: fieldname != null ? fieldname : "",
				filename: filename,
				contentType: partContentType,
				data: partData,
				size: partBodyLen,
			};
			parts.push(part);

			// If it's a text field (no filename), also merge into formBody
			if (filename == null && fieldname != null) {
				formFields.set(fieldname, partData.getString(0, partData.length));
			}

			// Move past the delimiter + \r\n
			pos = nextDelim + delimLen;
			if (pos + 2 <= bodyLen && body.get(pos) == 13 && body.get(pos + 1) == 10) {
				pos += 2;
			}
		}

		ctx.store.set(STORE_KEY, parts);

		// Merge text fields into formBody store key (same key as FormBody plugin)
		// so plugins like CSRF that read FormBody.get() work transparently
		// with multipart forms too. Only set if we have text fields.
		if (fieldCount > 0) {
			var existing:Dynamic = ctx.store.get(FormBody.STORE_KEY);
			if (existing != null) {
				// Merge into existing formBody map
				var existingMap:Map<String, String> = cast existing;
				for (key in formFields.keys()) {
					existingMap.set(key, formFields.get(key));
				}
			} else {
				ctx.store.set(FormBody.STORE_KEY, formFields);
			}
		}
	}

	/**
	 * Extract the boundary string from the Content-Type header.
	 * E.g. "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxk"
	 */
	static function extractBoundary(contentType:String):Null<String> {
		var idx = contentType.indexOf("boundary=");
		if (idx < 0) return null;
		var boundary = contentType.substring(idx + 9);
		// Strip quotes if present
		if (boundary.length >= 2 && boundary.charCodeAt(0) == 34) {
			var endQuote = boundary.indexOf('"', 1);
			if (endQuote > 0) {
				boundary = boundary.substring(1, endQuote);
			}
		}
		// Strip trailing whitespace/semicolons
		var end = boundary.length;
		while (end > 0) {
			var c = boundary.charCodeAt(end - 1);
			if (c == 32 || c == 9 || c == 59) { // space, tab, semicolon
				end--;
			} else {
				break;
			}
		}
		if (end < boundary.length) {
			boundary = boundary.substring(0, end);
		}
		return boundary.length > 0 ? boundary : null;
	}

	/**
	 * Extract a named parameter from Content-Disposition.
	 * E.g. from 'form-data; name="field1"; filename="test.txt"'
	 * extractDispositionParam(..., "name") returns "field1"
	 */
	static function extractDispositionParam(disposition:String, param:String):Null<String> {
		var search = param + '="';
		var idx = disposition.indexOf(search);
		if (idx < 0) {
			// Try without quotes: param=value
			search = param + "=";
			idx = disposition.indexOf(search);
			if (idx < 0) return null;
			var start = idx + search.length;
			var end = disposition.indexOf(";", start);
			if (end < 0) end = disposition.length;
			return StringTools.trim(disposition.substring(start, end));
		}
		var start = idx + search.length;
		var end = disposition.indexOf('"', start);
		if (end < 0) return null;
		return disposition.substring(start, end);
	}

}

/** A single part from a multipart/form-data request. */
typedef MultipartPart = {
	/** The field name from Content-Disposition */
	fieldname:String,

	/** The filename from Content-Disposition (null for text fields) */
	?filename:String,

	/** The Content-Type of the part (null for text fields without explicit type) */
	?contentType:String,

	/** The raw body data of the part */
	data:Bytes,

	/** Size of the part body in bytes (avoids Dynamic boxing issues with data.length) */
	size:Int,
};

/** Configuration for the Multipart plugin. */
typedef MultipartConfig = {
	/** Size and count limits */
	?limits:MultipartLimits,
};

/** Limits for multipart parsing. */
typedef MultipartLimits = {
	/** Maximum file size in bytes (default: 1MB) */
	?fileSize:Int,

	/** Maximum number of file fields (default: 10) */
	?files:Int,

	/** Maximum number of non-file fields (default: 100) */
	?fields:Int,

	/** Maximum field value size in bytes (default: 1MB) */
	?fieldSize:Int,
};
