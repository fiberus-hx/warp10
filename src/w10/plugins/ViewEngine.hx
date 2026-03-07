package w10.plugins;

import w10.Context;
import w10.types.Types;
import w10.types.Hook;

/**
 * Template rendering plugin for Warp10 using haxe.Template.
 *
 * Loads and renders template files from a views directory. Supports
 * variable substitution (::var::), conditionals (::if::), iteration
 * (::foreach::), and macro calls ($$macro()) via haxe.Template.
 *
 * Two operating modes:
 *
 *   - **Production** (cache: true, default): All templates are loaded
 *     and parsed at plugin registration time (before listen()). The
 *     template map is never mutated after registration, making it safe
 *     for concurrent access from multiple threads/fibers. This follows
 *     warp10's "build-once, read-many" architecture.
 *
 *   - **Development** (cache: false): Templates are read from disk and
 *     parsed on every render() call. Each read is fiber-local (no shared
 *     mutable state), so this is thread-safe but slower. Allows editing
 *     templates without restarting the server.
 *
 * Layout support:
 *
 *   A layout is a wrapper template (e.g. common HTML shell) that receives
 *   the rendered inner content under a configurable variable name (default:
 *   "content"). The data object is available in both the inner template
 *   and the layout.
 *
 * Usage:
 *
 *     app.register(ViewEngine.create({
 *         root: sys.FileSystem.fullPath("views"),
 *         layout: "layout",       // views/layout.html
 *     }));
 *
 *     app.get("/", (ctx) -> {
 *         ViewEngine.render(ctx, "home", {title: "Home", items: items});
 *     });
 *
 * views/layout.html:
 *
 *     <html>
 *     <head><title>::title::</title></head>
 *     <body>::content::</body>
 *     </html>
 *
 * views/home.html:
 *
 *     <h1>Welcome</h1>
 *     ::foreach items::<p>::__current__::</p>::end::
 *
 * Partial rendering (no layout, for htmx fragments):
 *
 *     app.get("/items", (ctx) -> {
 *         ViewEngine.render(ctx, "partials/item-list", {items: items}, null, true);
 *     });
 */
class ViewEngine {
	/** Store key for the engine instance */
	public static inline var STORE_KEY = "viewEngine";

	// =========================================================================
	// Plugin registration
	// =========================================================================

	/**
	 * Create a ViewEngine plugin.
	 *
	 * In production mode (cache: true, the default), all template files
	 * matching the configured extension are recursively loaded from the
	 * root directory and parsed into haxe.Template objects. This happens
	 * during plugin registration (before listen()), so the resulting map
	 * is immutable at the point where multi-threaded access begins.
	 *
	 * In development mode (cache: false), templates are read from disk
	 * on every render() call. Slower, but allows live editing.
	 *
	 * @param config ViewEngine configuration (root directory, layout, etc.)
	 */
	public static function create(config:ViewEngineConfig):PluginFn {
		// Resolve config defaults
		var root = config.root;
		var ext = config.ext != null ? config.ext : ".html";
		var cacheEnabled = config.cache != false; // default true
		var layoutName = config.layout;
		var layoutVar = config.layoutVar != null ? config.layoutVar : "content";

		// Pre-load templates if caching is enabled
		var templateCache:Map<String, haxe.Template> = null;
		var layoutTemplate:haxe.Template = null;

		if (cacheEnabled) {
			templateCache = new Map<String, haxe.Template>();
			scanAndLoad(root, root, ext, templateCache);

			// Resolve layout template from cache
			if (layoutName != null) {
				layoutTemplate = templateCache.get(layoutName);
				if (layoutTemplate == null) {
					trace('[ViewEngine] WARNING: layout "$layoutName" not found in $root');
				}
			}
		}

		// Build engine instance (immutable after this point when caching)
		var engine:ViewEngineInstance = {
			root: root,
			ext: ext,
			cache: cacheEnabled,
			layoutName: layoutName,
			layoutVar: layoutVar,
			templates: templateCache,
			layoutTemplate: layoutTemplate,
		};

		return (app:w10.Warp10) -> {
			app.addHook(OnRequest, (ctx:Context) -> {
				ctx.store.set(STORE_KEY, engine);
			});
		};
	}

	// =========================================================================
	// Static API
	// =========================================================================

	/**
	 * Render a template file and send as HTML response.
	 *
	 * Looks up the template by name (relative path without extension),
	 * renders it with the provided data, optionally wraps it in the
	 * layout template, and sends the result as text/html.
	 *
	 * @param ctx       Request context
	 * @param name      Template name (e.g. "home", "partials/nav")
	 * @param data      Data object for haxe.Template.execute()
	 * @param macros    Optional macro resolver for $$macro() calls
	 * @param noLayout  If true, skip layout wrapping for this render
	 */
	public static function render(ctx:Context, name:String, ?data:Dynamic, ?macros:Dynamic, ?noLayout:Bool):Void {
		var output = renderToString(ctx, name, data, macros, noLayout);
		if (output.length > 0) {
			ctx.html(output);
		}
	}

	/**
	 * Render a template to a string without sending a response.
	 *
	 * Useful for composing fragments, building email bodies, or
	 * combining multiple rendered partials before sending.
	 *
	 * @param ctx       Request context (for engine lookup and error logging)
	 * @param name      Template name (e.g. "home", "partials/nav")
	 * @param data      Data object for haxe.Template.execute()
	 * @param macros    Optional macro resolver for $$macro() calls
	 * @param noLayout  If true, skip layout wrapping for this render
	 * @return Rendered HTML string, or empty string on error
	 */
	public static function renderToString(ctx:Context, name:String, ?data:Dynamic, ?macros:Dynamic,
			?noLayout:Bool):String {
		var engine:ViewEngineInstance = cast ctx.store.get(STORE_KEY);
		if (engine == null) {
			ctx.error("ViewEngine not registered");
			return "";
		}

		// Get or load the template
		var template = getTemplate(ctx, engine, name);
		if (template == null) return "";

		// Render inner template
		var output = template.execute(data, macros);

		// Apply layout (unless disabled or not configured)
		if (noLayout != true) {
			output = applyLayout(ctx, engine, output, data, macros);
		}

		return output;
	}

	/**
	 * Render an inline template string and send as HTML response.
	 *
	 * Parses and renders the template string directly, without file
	 * loading or layout wrapping. Useful for small dynamic fragments.
	 *
	 * @param ctx          Request context
	 * @param templateStr  Template string with ::var:: syntax
	 * @param data         Data object for haxe.Template.execute()
	 * @param macros       Optional macro resolver for $$macro() calls
	 */
	public static function renderInline(ctx:Context, templateStr:String, ?data:Dynamic, ?macros:Dynamic):Void {
		var template = new haxe.Template(templateStr);
		ctx.html(template.execute(data, macros));
	}

	// =========================================================================
	// Internal helpers
	// =========================================================================

	/**
	 * Get a template by name, either from cache or from disk.
	 */
	static function getTemplate(ctx:Context, engine:ViewEngineInstance, name:String):Null<haxe.Template> {
		if (engine.cache && engine.templates != null) {
			// Production: lookup in pre-loaded cache
			var template = engine.templates.get(name);
			if (template == null) {
				ctx.error('ViewEngine: template "$name" not found');
			}
			return template;
		} else {
			// Dev mode: read from disk each time (fiber-local, thread-safe)
			return loadFromDisk(ctx, engine.root, name, engine.ext);
		}
	}

	/**
	 * Apply the layout template, wrapping the rendered content.
	 *
	 * Creates a new data object that includes all fields from the original
	 * data plus the rendered content under the layout variable name.
	 */
	static function applyLayout(ctx:Context, engine:ViewEngineInstance, content:String, data:Dynamic,
			macros:Dynamic):String {
		var layoutTpl:haxe.Template = null;

		if (engine.cache) {
			layoutTpl = engine.layoutTemplate;
		} else if (engine.layoutName != null) {
			// Dev mode: load layout from disk
			layoutTpl = loadFromDisk(ctx, engine.root, engine.layoutName, engine.ext);
		}

		if (layoutTpl == null) return content;

		var layoutData = wrapWithContent(data, engine.layoutVar, content);
		return layoutTpl.execute(layoutData, macros);
	}

	/**
	 * Read a template file from disk and parse it.
	 * Returns null on error (logs via ctx.error).
	 */
	static function loadFromDisk(ctx:Context, root:String, name:String, ext:String):Null<haxe.Template> {
		var path = root + "/" + name + ext;
		try {
			var content = sys.io.File.getContent(path);
			return new haxe.Template(content);
		} catch (e:Dynamic) {
			ctx.error('ViewEngine: failed to load "$name"', {path: path, err: Std.string(e)});
			return null;
		}
	}

	/**
	 * Recursively scan a directory and pre-load all template files.
	 *
	 * Template names are relative paths without extension:
	 *   views/home.html          -> "home"
	 *   views/partials/nav.html  -> "partials/nav"
	 *   views/layout.html        -> "layout"
	 */
	static function scanAndLoad(baseRoot:String, dir:String, ext:String, cache:Map<String, haxe.Template>):Void {
		try {
			var entries = sys.FileSystem.readDirectory(dir);
			for (entry in entries) {
				var fullPath = dir + "/" + entry;
				if (sys.FileSystem.isDirectory(fullPath)) {
					scanAndLoad(baseRoot, fullPath, ext, cache);
				} else if (StringTools.endsWith(entry, ext)) {
					var content = sys.io.File.getContent(fullPath);
					var template = new haxe.Template(content);
					// Compute relative name: strip root prefix and extension
					var relPath = fullPath.substring(baseRoot.length + 1);
					var name = relPath.substring(0, relPath.length - ext.length);
					cache.set(name, template);
				}
			}
		} catch (e:Dynamic) {
			trace('[ViewEngine] WARNING: failed to scan directory "$dir": $e');
		}
	}

	/**
	 * Create a wrapper object that includes all fields from the original
	 * data plus the rendered content under the layout variable name.
	 *
	 * This allows the layout template to access both ::content:: and
	 * any variables from the original data (e.g. ::title::).
	 */
	static function wrapWithContent(data:Dynamic, layoutVar:String, content:String):Dynamic {
		var wrapper:Dynamic = {};
		if (data != null) {
			var fields = Reflect.fields(data);
			for (field in fields) {
				Reflect.setField(wrapper, field, Reflect.field(data, field));
			}
		}
		Reflect.setField(wrapper, layoutVar, content);
		return wrapper;
	}
}

// =============================================================================
// Typedefs
// =============================================================================

/** Configuration for the ViewEngine plugin. */
typedef ViewEngineConfig = {
	/**
	 * Absolute path to the views directory.
	 *
	 * In production mode (cache: true), this directory is recursively
	 * scanned at registration time and all matching template files are
	 * loaded into memory.
	 */
	root:String,

	/**
	 * File extension for template files (default: ".html").
	 * Only files with this extension are loaded into the cache.
	 */
	?ext:String,

	/**
	 * Enable template caching (default: true).
	 *
	 * When true, all templates are pre-loaded at registration time
	 * (before listen()) and served from an immutable in-memory map.
	 * This is thread-safe and avoids file I/O during request handling.
	 *
	 * When false (development mode), templates are read from disk and
	 * parsed on every render() call. Each read is fiber-local, so this
	 * is still thread-safe, but slower.
	 */
	?cache:Bool,

	/**
	 * Default layout template name (without extension).
	 *
	 * If set, every render() call wraps the rendered content in this
	 * layout template. The rendered inner content is available in the
	 * layout under the variable name specified by layoutVar (default:
	 * "content"), so the layout can use ::content:: to insert it.
	 *
	 * Pass noLayout: true to render() to skip the layout for a
	 * specific render (e.g. htmx fragment responses).
	 *
	 * Example layout (views/layout.html):
	 *
	 *     <html>
	 *     <head><title>::title::</title></head>
	 *     <body>::content::</body>
	 *     </html>
	 */
	?layout:String,

	/**
	 * Variable name for the rendered content in the layout template
	 * (default: "content").
	 *
	 * The layout template accesses the inner content via ::content::
	 * (or whatever this is set to).
	 */
	?layoutVar:String,
};

/**
 * Internal engine state.
 *
 * When cache is true, the templates Map and layoutTemplate are populated
 * at registration time and never mutated afterwards. This follows
 * warp10's "build-once, read-many" pattern for thread safety.
 */
private typedef ViewEngineInstance = {
	root:String,
	ext:String,
	cache:Bool,
	?layoutName:String,
	layoutVar:String,
	?templates:Map<String, haxe.Template>,
	?layoutTemplate:haxe.Template,
};
