package w10.plugins;

import haxe.io.Bytes;
import fiberus.io.FD;
import fiberus.io.OpenFlags;
import w10.Context;
import w10.types.Types;
import w10.types.HttpMethod;
import w10.types.HttpStatus;

/**
 * SPA fallback ("rewriter") plugin for Warp10.
 *
 * Registers a not-found handler that serves the SPA shell (index.html) with
 * status 200 for any unmatched GET/HEAD route, so a client-side router can
 * handle deep links (reload/bookmark/share of paths like /users/42). The
 * original URL is preserved -- this is an internal rewrite, not a redirect.
 *
 * Explicit routes always win; only truly unmatched paths fall back. Non
 * GET/HEAD methods and excluded prefixes get a real 404 (so e.g. /api typos
 * don't return an HTML 200).
 *
 * Usage:
 *
 *     app.register(Rewriter.create({root: publicDir}));               // serves <root>/index.html
 *     app.register(Rewriter.create({root: dist, exclude: ["/api"]})); // keep /api as real 404
 */
class Rewriter {
	/**
	 * Create the SPA fallback plugin.
	 *
	 * @param config.root    Absolute path to the directory containing the shell
	 * @param config.index   Shell file name relative to root (default "index.html")
	 * @param config.exclude Path prefixes that keep returning a real 404
	 */
	public static function create(config:RewriterConfig):PluginFn {
		// Normalize root: strip trailing "/"
		var root = config.root;
		if (root.length > 1 && root.charAt(root.length - 1) == "/") {
			root = root.substring(0, root.length - 1);
		}

		var indexPath = root + "/" + (config.index != null ? config.index : "index.html");
		var exclude = config.exclude != null ? config.exclude : [];

		return (app:w10.Warp10) -> {
			app.setNotFoundHandler((ctx:Context) -> {
				// Only GET/HEAD navigations fall back; everything else 404s.
				if (ctx.method != HttpMethod.Get && ctx.method != HttpMethod.Head) {
					notFound(ctx);
					return;
				}

				// Excluded prefixes keep their real 404 (e.g. API routes).
				for (prefix in exclude) {
					if (StringTools.startsWith(ctx.path, prefix)) {
						notFound(ctx);
						return;
					}
				}

				serveIndex(ctx, indexPath);
			});
		};
	}

	/** Send the standard JSON 404 (matches Server.sendError shape). */
	static function notFound(ctx:Context):Void {
		ctx.status(HttpStatus.NOT_FOUND).json({statusCode: HttpStatus.NOT_FOUND, error: "Not Found"});
	}

	/**
	 * Read the SPA shell from disk and send it as text/html with status 200.
	 * Mirrors StaticFiles' buffer-based read; single fixed file, so no MIME
	 * table or path-traversal guard is needed.
	 */
	static function serveIndex(ctx:Context, path:String):Void {
		var fd = FD.open(path, OpenFlags.O_RDONLY);
		if (fd < 0) {
			notFound(ctx);
			return;
		}

		var size:Int = cast(FD.getSize(fd), Int);
		if (size <= 0) {
			FD.close(fd);
			notFound(ctx);
			return;
		}

		var buf = Bytes.alloc(size);
		var totalRead = 0;
		while (totalRead < size) {
			var n = FD.read(fd, buf, totalRead, size - totalRead);
			if (n <= 0) break;
			totalRead += n;
		}
		FD.close(fd);

		if (totalRead != size) {
			ctx.status(HttpStatus.INTERNAL_SERVER_ERROR).text("Read Error");
			return;
		}

		// Status stays 200 (Response default) so the client router can route.
		ctx.res.type("text/html; charset=UTF-8");
		ctx.res.send(buf);
	}
}

/** Configuration for the Rewriter (SPA fallback) plugin. */
typedef RewriterConfig = {
	/** Absolute path to the directory containing the SPA shell. */
	root:String,

	/** Shell file name relative to root (default: "index.html"). */
	?index:String,

	/** Path prefixes that should keep returning a real 404 (e.g. ["/api"]). */
	?exclude:Array<String>,
};
