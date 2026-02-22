package w10.utils;

import haxe.io.Bytes;

/**
 * Shared HTTP parsing utilities used by Server, FormBody, Multipart, etc.
 *
 * Centralises common patterns that were previously duplicated across
 * multiple files: header parsing, query-string / form-body parsing,
 * and byte-level scanning for the double-CRLF header terminator.
 */
class Http {
	/**
	 * Parse HTTP-style headers from a string block into a Map.
	 *
	 * Each line is expected to be `Key: Value` separated by `\r\n`.
	 * Keys are lowercased. Leading whitespace on values is trimmed
	 * (OWS per HTTP spec).
	 *
	 * @param headerStr  The raw header block (without the trailing \r\n\r\n)
	 * @param startLine  If > 0, skip the first N lines (e.g. 1 to skip the
	 *                   HTTP request line in a full header block)
	 * @param into       Optional existing map to populate (created if null)
	 * @return The populated header map
	 */
	public static function parseHeaders(headerStr:String, startLine:Int = 0, ?into:Map<String, String>):Map<String, String> {
		var result = into != null ? into : new Map<String, String>();
		var lines = headerStr.split("\r\n");
		var i = startLine;
		while (i < lines.length) {
			var line = lines[i];
			var colonIdx = line.indexOf(":");
			if (colonIdx > 0) {
				var key = line.substring(0, colonIdx).toLowerCase();
				var value = StringTools.ltrim(line.substring(colonIdx + 1));
				result.set(key, value);
			}
			i++;
		}
		return result;
	}

	/**
	 * Parse a `key=value&key=value` query/form string into a Map.
	 *
	 * Both keys and values are URL-decoded via `StringTools.urlDecode()`.
	 * Keys without a value (e.g. `flag&other=1`) are stored with an
	 * empty-string value.
	 *
	 * @param str   The raw query or form-body string
	 * @param into  Optional existing map to populate (created if null)
	 * @return The populated key-value map
	 */
	public static function parseKeyValuePairs(str:String, ?into:Map<String, String>):Map<String, String> {
		var result = into != null ? into : new Map<String, String>();
		var pairs = str.split("&");
		for (pair in pairs) {
			var eqIdx = pair.indexOf("=");
			if (eqIdx > 0) {
				var key = StringTools.urlDecode(pair.substring(0, eqIdx));
				var value = StringTools.urlDecode(pair.substring(eqIdx + 1));
				result.set(key, value);
			} else if (pair.length > 0) {
				result.set(StringTools.urlDecode(pair), "");
			}
		}
		return result;
	}

	/**
	 * Find the position of `\r\n\r\n` in a Bytes buffer.
	 *
	 * Used to locate the end of HTTP headers in a raw byte stream.
	 *
	 * @param buf       The byte buffer to scan
	 * @param startPos  Position to start scanning from
	 * @return The position of the first `\r`, or -1 if not found
	 */
	public static function findCrlfCrlf(buf:Bytes, startPos:Int):Int {
		var len = buf.length;
		var pos = startPos;
		while (pos <= len - 4) {
			if (buf.get(pos) == 13 && buf.get(pos + 1) == 10 && buf.get(pos + 2) == 13 && buf.get(pos + 3) == 10) {
				return pos;
			}
			pos++;
		}
		return -1;
	}

	/**
	 * Find the position of a byte sequence (needle) in a Bytes buffer.
	 *
	 * @param haystack  The buffer to search in
	 * @param needle    The byte sequence to search for
	 * @param startPos  Position to start scanning from
	 * @return The position of the first match, or -1 if not found
	 */
	public static function findBytes(haystack:Bytes, needle:Bytes, startPos:Int):Int {
		var hLen = haystack.length;
		var nLen = needle.length;
		if (nLen == 0) return startPos;
		if (startPos + nLen > hLen) return -1;

		var firstByte = needle.get(0);
		var pos = startPos;
		while (pos <= hLen - nLen) {
			if (haystack.get(pos) == firstByte) {
				var match = true;
				var j = 1;
				while (j < nLen) {
					if (haystack.get(pos + j) != needle.get(j)) {
						match = false;
						break;
					}
					j++;
				}
				if (match) return pos;
			}
			pos++;
		}
		return -1;
	}

	/**
	 * Extract the media type from a Content-Type header value.
	 *
	 * Strips parameters (`;charset=...`, `;boundary=...`) and trims
	 * whitespace, returning just the lowercased media type.
	 *
	 *     parseMediaType("text/html; charset=UTF-8")  →  "text/html"
	 *     parseMediaType("multipart/form-data; boundary=---abc")  →  "multipart/form-data"
	 *
	 * @param contentType  The raw Content-Type header value
	 * @return The media type portion, lowercased and trimmed
	 */
	public static function parseMediaType(contentType:String):String {
		var semiIdx = contentType.indexOf(";");
		var mt = semiIdx >= 0 ? contentType.substring(0, semiIdx) : contentType;
		return StringTools.trim(mt).toLowerCase();
	}
}
