package w10.plugins;

import haxe.io.Bytes;
import fiberus.io.FD;
import fiberus.io.OpenFlags;
import w10.Context;
import w10.types.Types;

/**
 * Static file serving plugin for Warp10.
 *
 * Inspired by @fastify/static. Registers a wildcard GET route that
 * serves files from a root directory under a URL prefix.
 *
 * Usage:
 *
 *     app.register(StaticFiles.create({
 *         root: "/path/to/public",
 *         prefix: "/static/"
 *     }));
 *
 * Because the plugin uses register(), it runs in an encapsulated scope.
 * Any hooks added before register() are inherited by the static route.
 *
 * Files are read into memory using FD.open/read/getSize (buffer-based I/O).
 * If the requested file is not found, the route responds with 404.
 */
class StaticFiles {
	/**
	 * Create a static file serving plugin.
	 *
	 * @param config.root   Absolute path to the directory to serve files from
	 * @param config.prefix URL prefix to match (default: "/"). Must end with "/"
	 */
	public static function create(config:StaticConfig):PluginFn {
		// Normalize prefix: ensure it starts with "/" and ends with "/"
		var prefix = config.prefix != null ? config.prefix : "/";
		if (prefix.length == 0) prefix = "/";
		if (prefix.charAt(0) != "/") prefix = "/" + prefix;
		if (prefix.charAt(prefix.length - 1) != "/") prefix = prefix + "/";

		// Normalize root: strip trailing "/"
		var root = config.root;
		if (root.length > 1 && root.charAt(root.length - 1) == "/") {
			root = root.substring(0, root.length - 1);
		}

		return (app:w10.Warp10) -> {
			// Register wildcard route: GET /prefix/*
			// The "*" param captures everything after the prefix.
			app._addRoute(w10.types.HttpMethod.Get, prefix + "*", (ctx:Context) -> {
				serveStatic(ctx, root);
			});

			// Also register for HEAD (standard for static file servers)
			app._addRoute(w10.types.HttpMethod.Head, prefix + "*", (ctx:Context) -> {
				serveStatic(ctx, root);
			});

			// Serve index.html when prefix itself is requested (no wildcard match)
			app._addRoute(w10.types.HttpMethod.Get, prefix.substring(0, prefix.length - 1), (ctx:Context) -> {
				serveFile(ctx, root, "index.html");
			});
		};
	}

	/**
	 * Serve a static file for a wildcard route.
	 *
	 * Reads the "*" param from the route match, guards against path
	 * traversal, resolves the file, and sends it. Responds 404 if
	 * the file is not found.
	 */
	static function serveStatic(ctx:Context, root:String):Void {
		var relPath = ctx.params.get("*");

		// Empty wildcard -> try index.html
		if (relPath == null || relPath.length == 0) relPath = "index.html";

		serveFile(ctx, root, relPath);
	}

	/**
	 * Resolve and serve a file from the root directory.
	 */
	static function serveFile(ctx:Context, root:String, relPath:String):Void {
		// Guard against path traversal
		if (containsDotDot(relPath)) {
			ctx.status(403).text("Forbidden");
			return;
		}

		// Build the full filesystem path
		var fullPath = root + "/" + relPath;

		// Try to open the file (read-only)
		var fd = FD.open(fullPath, OpenFlags.O_RDONLY);
		if (fd < 0) {
			ctx.status(404).text("Not Found");
			return;
		}

		// Get file size
		var sizeI64 = FD.getSize(fd);
		var size:Int = cast(sizeI64, Int);

		if (size <= 0) {
			FD.close(fd);
			ctx.status(404).text("Not Found");
			return;
		}

		// Read file contents into buffer
		var buf = Bytes.alloc(size);
		var totalRead = 0;
		while (totalRead < size) {
			var n = FD.read(fd, buf, totalRead, size - totalRead);
			if (n <= 0) break;
			totalRead += n;
		}
		FD.close(fd);

		if (totalRead != size) {
			ctx.status(500).text("Read Error");
			return;
		}

		// Determine MIME type from file extension
		var mime = getMimeType(relPath);

		// Send the file as the response
		ctx.res.type(mime);
		ctx.res.send(buf);
	}

	/**
	 * Check if a path contains ".." segments (path traversal attempt).
	 */
	static function containsDotDot(path:String):Bool {
		if (path == "..") return true;
		if (StringTools.startsWith(path, "../")) return true;
		if (path.indexOf("/../") >= 0) return true;
		if (path.length >= 3) {
			var end = path.substring(path.length - 3);
			if (end == "/..") return true;
		}
		return false;
	}

	/**
	 * Determine MIME type from file extension.
	 * Returns "application/octet-stream" for unknown extensions.
	 */
	static function getMimeType(path:String):String {
		var dotIdx = path.lastIndexOf(".");
		if (dotIdx < 0) return "application/octet-stream";

		var ext = path.substring(dotIdx + 1).toLowerCase();

		// Common MIME types
		if (ext == "html" || ext == "htm") return "text/html; charset=UTF-8";
		if (ext == "css") return "text/css; charset=UTF-8";
		if (ext == "js" || ext == "mjs") return "text/javascript; charset=UTF-8";
		if (ext == "json") return "application/json; charset=UTF-8";
		if (ext == "xml") return "application/xml; charset=UTF-8";
		if (ext == "txt") return "text/plain; charset=UTF-8";
		if (ext == "csv") return "text/csv; charset=UTF-8";

		// Images
		if (ext == "png") return "image/png";
		if (ext == "jpg" || ext == "jpeg") return "image/jpeg";
		if (ext == "gif") return "image/gif";
		if (ext == "svg") return "image/svg+xml";
		if (ext == "ico") return "image/x-icon";
		if (ext == "webp") return "image/webp";
		if (ext == "avif") return "image/avif";

		// Fonts
		if (ext == "woff") return "font/woff";
		if (ext == "woff2") return "font/woff2";
		if (ext == "ttf") return "font/ttf";
		if (ext == "otf") return "font/otf";

		// Media
		if (ext == "mp3") return "audio/mpeg";
		if (ext == "mp4") return "video/mp4";
		if (ext == "webm") return "video/webm";
		if (ext == "ogg") return "audio/ogg";
		if (ext == "wav") return "audio/wav";

		// Archives / binary
		if (ext == "pdf") return "application/pdf";
		if (ext == "zip") return "application/zip";
		if (ext == "gz" || ext == "gzip") return "application/gzip";
		if (ext == "wasm") return "application/wasm";

		return "application/octet-stream";
	}
}

/** Configuration for the StaticFiles plugin. */
typedef StaticConfig = {
	/** Absolute path to the directory to serve files from. */
	root:String,

	/** URL prefix to match (default: "/"). Requests starting with this
	 *  prefix will be checked against the root directory. */
	?prefix:String,
};
