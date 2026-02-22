package w10.plugins;

import haxe.io.Bytes;
import w10.Context;
import w10.types.Types;
import w10.types.HttpMethod;

/**
 * Swagger UI plugin for Warp10.
 *
 * Inspired by @fastify/swagger-ui: serves an interactive Swagger UI page
 * that loads assets from a CDN (unpkg.com) and points at the OpenAPI JSON
 * endpoint served by the Swagger plugin.
 *
 * This is a separate plugin from Swagger (spec generator), following the
 * Fastify model where @fastify/swagger and @fastify/swagger-ui are distinct
 * packages that compose together.
 *
 * Usage:
 *
 *     // Register both plugins -- they auto-discover each other via defaults
 *     app.register(Swagger.create({
 *         openapi: { info: { title: "My API", version: "1.0.0" } },
 *     }));
 *     app.register(SwaggerUi.create({
 *         title: "My API Docs",
 *     }));
 *
 *     // Now visit http://localhost:8080/docs in a browser
 *
 * The plugin serves a single GET route at `routePrefix` (default "/docs")
 * that returns a self-contained HTML page. All Swagger UI assets (JS, CSS)
 * are loaded from unpkg.com CDN -- no local files needed.
 *
 * For the spec endpoint, the Swagger plugin should be registered with its
 * default path ("/docs/openapi.json") or a matching `specUrl` should be
 * provided to SwaggerUi.
 */
class SwaggerUi {
	/** Default swagger-ui-dist version served from CDN */
	static inline var DEFAULT_VERSION = "5.31.2";

	/**
	 * Create a SwaggerUi plugin.
	 *
	 * @param config  Plugin configuration (route prefix, spec URL, title, etc.)
	 * @return A PluginFn suitable for app.register()
	 */
	public static function create(?config:SwaggerUiConfig):PluginFn {
		var cfg:SwaggerUiConfig = config != null ? config : {};
		var routePrefix = cfg.routePrefix != null ? cfg.routePrefix : "/docs";
		var specUrl = cfg.specUrl != null ? cfg.specUrl : routePrefix + "/openapi.json";
		var title = cfg.title != null ? cfg.title : "Swagger UI";
		var version = cfg.version != null ? cfg.version : DEFAULT_VERSION;

		// Serialize uiConfig to JSON for embedding in the init script
		var uiConfigJson = "{}";
		if (cfg.uiConfig != null) {
			uiConfigJson = haxe.Json.stringify(cfg.uiConfig);
		}

		// Build the HTML page once at registration time (it's static)
		var html = buildHtml(title, specUrl, version, uiConfigJson);
		var htmlBytes = Bytes.ofString(html);

		return (app:w10.Warp10) -> {
			// Serve the Swagger UI page
			app._addRoute(Get, routePrefix, (ctx:Context) -> {
				ctx.res.header("Cache-Control", "no-cache");
				ctx.res.type("text/html; charset=UTF-8");
				ctx.res.send(htmlBytes);
			});
		};
	}

	/**
	 * Build the self-contained Swagger UI HTML page.
	 *
	 * Loads all assets from unpkg.com CDN. The init script configures
	 * SwaggerUIBundle to fetch the spec from specUrl and applies any
	 * user-provided uiConfig overrides.
	 */
	static function buildHtml(title:String, specUrl:String, version:String, uiConfigJson:String):String {
		var cdn = "https://unpkg.com/swagger-ui-dist@" + version;

		return '<!DOCTYPE html>\n'
			+ '<html lang="en">\n'
			+ "<head>\n"
			+ '  <meta charset="UTF-8">\n'
			+ '  <title>'
			+ escapeHtml(title)
			+ "</title>\n"
			+ '  <link rel="stylesheet" href="'
			+ cdn
			+ '/swagger-ui.css" />\n'
			+ '  <link rel="stylesheet" href="'
			+ cdn
			+ '/index.css" />\n'
			+ '  <link rel="icon" type="image/png" href="'
			+ cdn
			+ '/favicon-32x32.png" sizes="32x32" />\n'
			+ '  <link rel="icon" type="image/png" href="'
			+ cdn
			+ '/favicon-16x16.png" sizes="16x16" />\n'
			+ "</head>\n"
			+ "<body>\n"
			+ '  <div id="swagger-ui"></div>\n'
			+ '  <script src="'
			+ cdn
			+ '/swagger-ui-bundle.js"></script>\n'
			+ '  <script src="'
			+ cdn
			+ '/swagger-ui-standalone-preset.js"></script>\n'
			+ "  <script>\n"
			+ "    window.onload = function() {\n"
			+ "      var baseConfig = {\n"
			+ '        url: "'
			+ escapeJs(specUrl)
			+ '",\n'
			+ "        dom_id: '#swagger-ui',\n"
			+ "        deepLinking: true,\n"
			+ "        presets: [\n"
			+ "          SwaggerUIBundle.presets.apis,\n"
			+ "          SwaggerUIStandalonePreset\n"
			+ "        ],\n"
			+ "        plugins: [\n"
			+ "          SwaggerUIBundle.plugins.DownloadUrl\n"
			+ "        ],\n"
			+ '        layout: "StandaloneLayout"\n'
			+ "      };\n"
			+ "      var userConfig = "
			+ uiConfigJson
			+ ";\n"
			+ "      var merged = baseConfig;\n"
			+ "      for (var k in userConfig) {\n"
			+ "        if (userConfig.hasOwnProperty(k)) merged[k] = userConfig[k];\n"
			+ "      }\n"
			+ "      window.ui = SwaggerUIBundle(merged);\n"
			+ "    };\n"
			+ "  </script>\n"
			+ "</body>\n"
			+ "</html>\n";
	}

	/** Escape HTML special characters in a string (including quotes). */
	static inline function escapeHtml(s:String):String {
		return StringTools.htmlEscape(s, true);
	}

	/**
	 * Escape a string for embedding inside a JavaScript double-quoted string literal.
	 *
	 * Uses haxe.Json.stringify which handles all necessary escaping (\", \\, \n, etc.)
	 * and strips the surrounding quotes since the template already provides them.
	 */
	static function escapeJs(s:String):String {
		var quoted = haxe.Json.stringify(s);
		// Strip the surrounding double quotes added by stringify
		return quoted.substring(1, quoted.length - 1);
	}
}

/** Configuration for the SwaggerUi plugin. */
typedef SwaggerUiConfig = {
	/**
	 * Route path to serve the Swagger UI page.
	 * Default: "/docs"
	 */
	?routePrefix:String,

	/**
	 * URL of the OpenAPI JSON spec endpoint.
	 * Default: routePrefix + "/openapi.json"
	 *
	 * This should match the `path` option of the Swagger plugin.
	 * With both plugins using defaults, this is "/docs/openapi.json".
	 */
	?specUrl:String,

	/**
	 * Page title shown in the browser tab.
	 * Default: "Swagger UI"
	 */
	?title:String,

	/**
	 * swagger-ui-dist version to load from the CDN.
	 * Default: "5.31.2"
	 */
	?version:String,

	/**
	 * Configuration options passed to SwaggerUIBundle().
	 *
	 * Common options:
	 *   - docExpansion: "list" | "full" | "none"
	 *   - deepLinking: Bool
	 *   - filter: Bool (enable search filter)
	 *   - defaultModelsExpandDepth: Int (-1 to hide models)
	 *   - displayRequestDuration: Bool
	 *   - tryItOutEnabled: Bool
	 *
	 * See: https://swagger.io/docs/open-source-tools/swagger-ui/usage/configuration/
	 */
	?uiConfig:Dynamic,
};
