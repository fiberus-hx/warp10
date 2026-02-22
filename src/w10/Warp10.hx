package w10;

#if !macro
import w10.types.Types;
import w10.types.HttpMethod;
import w10.types.Hook;
#end

/**
 * Warp10 - Blazing-fast web framework for Fiberus
 *
 * Inspired by Go Fiber (synchronous-style API) and Fastify (plugin/hook system).
 * Each request runs in its own fiber -- handlers look blocking but suspend
 * automatically on I/O via Fiberus' io_uring integration.
 *
 * Route handlers can declare typed parameters that are automatically extracted
 * from route `:param` segments at zero runtime cost -- the extraction code is
 * generated at compile time via macros:
 *
 *     final app = new Warp10();
 *
 *     // Simple handler (no extra params -- works as before)
 *     app.get("/", ctx -> ctx.text("Hello World"));
 *
 *     // Typed params -- extracted and converted automatically
 *     app.get("/hello/:name/:age", (ctx: Context, name: String, age: Int) -> {
 *         ctx.text('Hello $name, you are $age years old');
 *     });
 *
 *     // Function references work too
 *     app.get("/users/:id", UsersController.show);
 *
 *     app.listen({port: 3000}, () -> trace("Listening"));
 *
 * Supported parameter types: String, Int, Float, Bool, Null<T>.
 * Parameter names are validated against route :param segments at compile time.
 */
class Warp10 {
	#if !macro
	var router:Router;
	var prefix:String;
	var serverConfig:Null<ServerConfig>;

	/** Built-in structured logger. Non-null when `logging: true` in config. */
	public var log:Null<w10.utils.Logger>;

	/** Hook arrays -- one per lifecycle point */
	var onRequestHooks:Array<HookFn>;
	var preHandlerHooks:Array<HookFn>;
	var onResponseHooks:Array<HookFn>;

	/**
	 * Route metadata registry for OpenAPI/Swagger generation.
	 *
	 * Every _addRoute() call pushes a RouteInfo here. Shared across
	 * all scopes (register/route children) so the Swagger plugin can
	 * see all routes from any scope. The macro auto-populates param
	 * schemas; users can enrich entries via describe().
	 */
	public var routeRegistry:Array<RouteInfo>;
	#end

	/**
	 * Create a new Warp10 instance.
	 *
	 * @param config Optional server configuration (thread count, timeouts, etc.)
	 */
	#if !macro
	public function new(?config:ServerConfig) {
		this.router = new Router();
		this.prefix = "";
		this.serverConfig = config;
		this.onRequestHooks = [];
		this.preHandlerHooks = [];
		this.onResponseHooks = [];
		this.routeRegistry = [];

		if (config != null && config.logging == true) {
			final serviceName = config.serviceName ?? "warp10";
			this.log = new w10.utils.Logger({level: Info, name: serviceName});
		}
	}
	#end

	#if !macro
	/**
	 * Private constructor for sub-routers created via route().
	 *
	 * Sub-routers SHARE the parent's hook arrays (same encapsulation
	 * context, just a different prefix). This means hooks added on
	 * the sub-router also affect routes registered on the parent.
	 * For isolation, use register() instead.
	 */
	function initSubRouter(router:Router, prefix:String):Warp10 {
		var sub = new Warp10();
		sub.router = router;
		sub.prefix = prefix;
		// Share hook arrays -- same scope, different prefix
		sub.onRequestHooks = onRequestHooks;
		sub.preHandlerHooks = preHandlerHooks;
		sub.onResponseHooks = onResponseHooks;
		sub.routeRegistry = routeRegistry;
		sub.log = log;
		return sub;
	}
	#end

	// =========================================================================
	// Plugin & Hook registration
	// =========================================================================

	#if !macro
	/**
	 * Register a plugin in an encapsulated scope.
	 *
	 * Creates a child Warp10 instance that inherits the current hooks
	 * (by copying the arrays). Hooks added by the plugin only apply
	 * to routes registered within the plugin -- not to routes in the
	 * parent or sibling scopes.
	 *
	 * This matches Fastify's encapsulation model:
	 *
	 *     app.addHook(OnRequest, globalAuth);
	 *
	 *     app.register((admin) -> {
	 *         admin.addHook(PreHandler, requireAdmin);  // only for admin routes
	 *         final api = admin.route("/admin");
	 *         api.get("/dashboard", handler);  // has globalAuth + requireAdmin
	 *     });
	 *
	 *     app.get("/public", handler);  // only has globalAuth
	 */
	public function register(plugin:PluginFn):Warp10 {
		// Create a child scope that inherits current hooks (copy, not share)
		var child = new Warp10();
		child.router = this.router;
		child.prefix = this.prefix;
		child.serverConfig = this.serverConfig;
		child.log = this.log;
		child.onRequestHooks = this.onRequestHooks.copy();
		child.preHandlerHooks = this.preHandlerHooks.copy();
		child.onResponseHooks = this.onResponseHooks.copy();
		child.routeRegistry = this.routeRegistry; // shared, not copied

		// Let the plugin configure the child scope
		plugin(child);
		return this;
	}

	/**
	 * Apply a plugin to this scope without creating a child.
	 *
	 * Unlike register(), this does NOT create a new encapsulation context.
	 * Hooks and routes added by the plugin apply directly to this scope.
	 * Use this for plugins that add hooks you want to affect routes
	 * registered on the same scope (e.g. CSRF, CORS, rate limiting).
	 *
	 *     app.register((scope) -> {
	 *         scope.use(Csrf.create({}));    // hook applies to scope
	 *         scope.get("/form", handler);   // route has CSRF hook
	 *         scope.post("/submit", handler);
	 *     });
	 */
	public function use(plugin:PluginFn):Warp10 {
		plugin(this);
		return this;
	}

	/**
	 * Add a hook function to a request lifecycle point.
	 *
	 * Hooks run in registration order. OnRequest and PreHandler hooks
	 * can short-circuit the request by sending a response (the chain
	 * stops when ctx.res.sent becomes true). OnResponse hooks always run.
	 *
	 * Hooks are scoped: they only apply to routes registered on this
	 * Warp10 instance (and child scopes created via register()).
	 *
	 *     app.addHook(OnRequest, (ctx) -> {
	 *         if (ctx.getHeader("Authorization") == null) {
	 *             ctx.status(401).text("Unauthorized");
	 *         }
	 *     });
	 */
	public function addHook(point:HookPoint, fn:HookFn):Warp10 {
		switch (point) {
			case OnRequest:
				onRequestHooks.push(fn);
			case PreHandler:
				preHandlerHooks.push(fn);
			case OnResponse:
				onResponseHooks.push(fn);
		}
		return this;
	}
	/**
	 * Annotate a previously registered route with OpenAPI schema metadata.
	 *
	 * Finds the matching RouteInfo by method and path, then merges
	 * the provided schema fields into the existing schema (preserving
	 * auto-generated params/querystring from the macro).
	 *
	 *     app.get("/users/:id", handler);
	 *     app.describe(Get, "/users/:id", {
	 *         summary: "Get user by ID",
	 *         tags: ["users"],
	 *         response: { "200": { description: "User found" } },
	 *     });
	 *
	 * @param method  The HTTP method of the route to describe
	 * @param path    The route path (must match exactly as registered)
	 * @param schema  Schema fields to merge
	 */
	public function describe(method:HttpMethod, path:String, schema:RouteSchema):Warp10 {
		var fullPath = prefix + path;
		for (info in routeRegistry) {
			if (info.path == fullPath && HttpMethodTools.toString(info.method) == HttpMethodTools.toString(method)) {
				if (info.schema == null) {
					info.schema = schema;
				} else {
					// Merge: user-provided fields overwrite, but preserve
					// auto-generated params/querystring if not overridden
					if (schema.summary != null) info.schema.summary = schema.summary;
					if (schema.description != null) info.schema.description = schema.description;
					if (schema.tags != null) info.schema.tags = schema.tags;
					if (schema.operationId != null) info.schema.operationId = schema.operationId;
					if (schema.deprecated != null) info.schema.deprecated = schema.deprecated;
					if (schema.hide != null) info.schema.hide = schema.hide;
					if (schema.params != null) info.schema.params = schema.params;
					if (schema.querystring != null) info.schema.querystring = schema.querystring;
					if (schema.body != null) info.schema.body = schema.body;
					if (schema.response != null) info.schema.response = schema.response;
					if (schema.security != null) info.schema.security = schema.security;
					if (schema.consumes != null) info.schema.consumes = schema.consumes;
					if (schema.produces != null) info.schema.produces = schema.produces;
				}
				return this;
			}
		}
		return this;
	}
	#end

	// =========================================================================
	// Route registration (macro-powered)
	// =========================================================================

	/** Register a GET route */
	public macro function get(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Get", path, handler);
	}

	/** Register a POST route */
	public macro function post(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Post", path, handler);
	}

	/** Register a PUT route */
	public macro function put(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Put", path, handler);
	}

	/** Register a DELETE route */
	public macro function delete(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Delete", path, handler);
	}

	/** Register a PATCH route */
	public macro function patch(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Patch", path, handler);
	}

	/** Register a HEAD route */
	public macro function head(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Head", path, handler);
	}

	/** Register an OPTIONS route */
	public macro function options(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildRouteCall(ethis, "Options", path, handler);
	}

	/** Register a handler for all HTTP methods */
	public macro function all(ethis:haxe.macro.Expr, path:haxe.macro.Expr, handler:haxe.macro.Expr):haxe.macro.Expr {
		return w10.macros.Router.buildAllRouteCall(ethis, path, handler);
	}

	// =========================================================================
	// Runtime helpers (called by macro-generated code)
	// =========================================================================

	#if !macro
	/**
	 * Register a route handler for a single HTTP method.
	 * Called by macro-generated code -- not intended for direct use.
	 *
	 * Snapshots the current scope's hook arrays into the RouteEntry,
	 * so the route carries exactly the hooks that were registered at
	 * this point in this encapsulation context.
	 */
	public function _addRoute(method:HttpMethod, path:String, handler:RouteHandler, ?schema:RouteSchema):Warp10 {
		var fullPath = prefix + path;
		var entry:RouteEntry = {
			handler: handler,
			onRequestHooks: onRequestHooks,
			preHandlerHooks: preHandlerHooks,
			onResponseHooks: onResponseHooks,
		};
		router.add(method, fullPath, entry);
		routeRegistry.push({method: method, path: fullPath, schema: schema});
		return this;
	}

	/**
	 * Register a route handler for all HTTP methods.
	 * Called by macro-generated code -- not intended for direct use.
	 */
	public function _addAllRoutes(path:String, handler:RouteHandler, ?schema:RouteSchema):Warp10 {
		var fullPath = prefix + path;
		var entry:RouteEntry = {
			handler: handler,
			onRequestHooks: onRequestHooks,
			preHandlerHooks: preHandlerHooks,
			onResponseHooks: onResponseHooks,
		};
		router.add(Get, fullPath, entry);
		router.add(Post, fullPath, entry);
		router.add(Put, fullPath, entry);
		router.add(Delete, fullPath, entry);
		router.add(Patch, fullPath, entry);
		router.add(Head, fullPath, entry);
		router.add(Options, fullPath, entry);
		routeRegistry.push({method: Get, path: fullPath, schema: schema});
		routeRegistry.push({method: Post, path: fullPath, schema: schema});
		routeRegistry.push({method: Put, path: fullPath, schema: schema});
		routeRegistry.push({method: Delete, path: fullPath, schema: schema});
		routeRegistry.push({method: Patch, path: fullPath, schema: schema});
		routeRegistry.push({method: Head, path: fullPath, schema: schema});
		routeRegistry.push({method: Options, path: fullPath, schema: schema});
		return this;
	}

	/**
	 * Create a sub-router with a path prefix.
	 *
	 * Routes registered on the sub-router will be prefixed with the
	 * given path. Sub-routers share the same underlying Router instance,
	 * so routes are resolved in a single trie lookup.
	 *
	 *     final api = app.route("/api/v1");
	 *     api.get("/users", ctx -> ctx.json({users: []}));
	 *     // Matches GET /api/v1/users
	 */
	public function route(pathPrefix:String):Warp10 {
		return initSubRouter(router, prefix + pathPrefix);
	}

	// =========================================================================
	// Server lifecycle
	// =========================================================================

	/**
	 * Start the HTTP server.
	 *
	 * This method blocks the calling fiber -- it enters the accept loop
	 * and never returns under normal operation.
	 *
	 * @param options Host and port to listen on
	 * @param onReady Optional callback fired once the server is ready
	 */
	public function listen(options:ListenOptions, ?onReady:Void->Void):Void {
		var host = options.host != null ? options.host : "0.0.0.0";
		var port = options.port;

		var server = new Server(router, serverConfig, log);
		server.start(host, port, onReady);
	}
	#end
}
