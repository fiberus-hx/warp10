package w10.plugins;

import w10.Context;
import w10.types.Types;
import w10.types.HttpMethod;

/**
 * OpenAPI 3.0.3 specification generator plugin for Warp10.
 *
 * Inspired by @fastify/swagger: auto-discovers routes from the route
 * registry and generates an OpenAPI specification. Path and query parameter
 * types are auto-populated at compile time by the Router macro from typed
 * handler signatures.
 *
 * V1 is spec-only: serves the OpenAPI JSON document at a configurable
 * endpoint (default `/docs/openapi.json`). No bundled Swagger UI.
 *
 * Usage:
 *
 *     app.register(Swagger.create({
 *         path: "/docs/openapi.json",    // default
 *         openapi: {
 *             info: { title: "My API", version: "1.0.0" },
 *             servers: [{ url: "http://localhost:8080" }],
 *             tags: [
 *                 { name: "users", description: "User operations" },
 *             ],
 *         },
 *     }));
 *
 *     // Enrich routes with summaries, tags, response schemas:
 *     app.get("/users/:id", handler);
 *     app.describe(Get, "/users/:id", {
 *         summary: "Get user by ID",
 *         tags: ["users"],
 *         response: { "200": { description: "User found" } },
 *     });
 *
 * The plugin registers a GET route for the spec endpoint. Like all
 * Warp10 plugins, it should be registered via app.register() for
 * proper encapsulation scoping.
 */
class Swagger {
	/**
	 * Create a Swagger/OpenAPI plugin.
	 *
	 * @param config  Plugin configuration (spec metadata, endpoint path, filtering)
	 * @return A PluginFn suitable for app.register()
	 */
	public static function create(?config:SwaggerConfig):PluginFn {
		var cfg:SwaggerConfig = config != null ? config : {};
		var specPath = cfg.path != null ? cfg.path : "/docs/openapi.json";
		var hiddenTag = cfg.hiddenTag;
		var hideUntagged = cfg.hideUntagged == true;

		// Extract OpenAPI metadata from config
		var openapi:Null<OpenApiConfig> = cfg.openapi;

		return (app:w10.Warp10) -> {
			// Capture the routeRegistry reference (shared across all scopes)
			var registry = app.routeRegistry;

			// Register the spec endpoint
			app._addRoute(Get, specPath, (ctx:Context) -> {
				var spec = buildSpec(registry, openapi, hiddenTag, hideUntagged);
				ctx.res.header("Cache-Control", "no-cache");
				ctx.json(spec);
			});
		};
	}

	/**
	 * Build the complete OpenAPI 3.0.3 specification from the route registry.
	 */
	static function buildSpec(
		registry:Array<RouteInfo>,
		openapi:Null<OpenApiConfig>,
		hiddenTag:Null<String>,
		hideUntagged:Bool
	):Dynamic {
		var spec:Dynamic = {};

		// OpenAPI version
		Reflect.setField(spec, "openapi", "3.0.3");

		// Info object (required by OpenAPI)
		if (openapi != null && openapi.info != null) {
			Reflect.setField(spec, "info", openapi.info);
		} else {
			Reflect.setField(spec, "info", {title: "Warp10 API", version: "1.0.0"});
		}

		// Servers
		if (openapi != null && openapi.servers != null) {
			Reflect.setField(spec, "servers", openapi.servers);
		}

		// Tags
		if (openapi != null && openapi.tags != null) {
			Reflect.setField(spec, "tags", openapi.tags);
		}

		// Components (reusable schemas, security schemes, etc.)
		if (openapi != null && openapi.components != null) {
			Reflect.setField(spec, "components", openapi.components);
		}

		// Build paths object from route registry
		var paths:Dynamic = {};

		for (info in registry) {
			// Skip hidden routes
			if (info.schema != null && info.schema.hide == true) continue;

			// Skip routes with the hidden tag
			if (hiddenTag != null && info.schema != null && info.schema.tags != null) {
				if (info.schema.tags.indexOf(hiddenTag) >= 0) continue;
			}

			// Skip untagged routes if hideUntagged is true
			if (hideUntagged) {
				if (info.schema == null || info.schema.tags == null || info.schema.tags.length == 0) {
					continue;
				}
			}

			// Convert Warp10 path format (:param, *) to OpenAPI format ({param})
			var oaPath = convertPath(info.path);
			var methodStr = HttpMethodTools.toString(info.method).toLowerCase();

			// Get or create the path item
			var pathItem:Dynamic = Reflect.field(paths, oaPath);
			if (pathItem == null) {
				pathItem = {};
				Reflect.setField(paths, oaPath, pathItem);
			}

			// Build the operation object
			var operation = buildOperation(info, oaPath);
			Reflect.setField(pathItem, methodStr, operation);
		}

		Reflect.setField(spec, "paths", paths);

		return spec;
	}

	/**
	 * Convert a Warp10 route path to OpenAPI path format.
	 *
	 * - `:paramName` becomes `{paramName}`
	 * - `*` wildcard becomes a trailing path note (kept as-is with description)
	 */
	static function convertPath(path:String):String {
		var result = new StringBuf();
		var segments = path.split("/");
		var first = true;

		for (seg in segments) {
			if (seg.length == 0 && first) {
				first = false;
				continue;
			}

			result.add("/");

			if (seg.length > 0 && seg.charAt(0) == ":") {
				result.add("{");
				result.add(seg.substr(1));
				result.add("}");
			} else if (seg == "*") {
				result.add("{wildcard}");
			} else {
				result.add(seg);
			}
		}

		var s = result.toString();
		if (s.length == 0) return "/";
		return s;
	}

	/**
	 * Build an OpenAPI operation object from a RouteInfo entry.
	 */
	static function buildOperation(info:RouteInfo, oaPath:String):Dynamic {
		var op:Dynamic = {};
		var schema = info.schema;

		// Summary
		if (schema != null && schema.summary != null) {
			Reflect.setField(op, "summary", schema.summary);
		}

		// Description
		if (schema != null && schema.description != null) {
			Reflect.setField(op, "description", schema.description);
		}

		// Tags
		if (schema != null && schema.tags != null) {
			Reflect.setField(op, "tags", schema.tags);
		}

		// OperationId
		if (schema != null && schema.operationId != null) {
			Reflect.setField(op, "operationId", schema.operationId);
		}

		// Deprecated
		if (schema != null && schema.deprecated == true) {
			Reflect.setField(op, "deprecated", true);
		}

		// Parameters (path + query)
		var parameters:Array<Dynamic> = [];

		// Path parameters from schema (macro-generated with types)
		if (schema != null && schema.params != null) {
			var props:Dynamic = Reflect.field(schema.params, "properties");
			var required:Null<Array<Dynamic>> = Reflect.field(schema.params, "required");

			if (props != null) {
				var fieldNames = Reflect.fields(props);
				for (name in fieldNames) {
					var propSchema:Dynamic = Reflect.field(props, name);
					var param:Dynamic = {};
					Reflect.setField(param, "name", name);
					Reflect.setField(param, "in", "path");
					Reflect.setField(param, "required", true); // path params always required
					Reflect.setField(param, "schema", propSchema);
					parameters.push(param);
				}
			}
		} else {
			// Auto-extract path params from :param segments even without schema
			var segments = info.path.split("/");
			for (seg in segments) {
				if (seg.length > 0 && seg.charAt(0) == ":") {
					var param:Dynamic = {};
					Reflect.setField(param, "name", seg.substr(1));
					Reflect.setField(param, "in", "path");
					Reflect.setField(param, "required", true);
					Reflect.setField(param, "schema", {type: "string"});
					parameters.push(param);
				}
			}
		}

		// Query parameters from schema
		if (schema != null && schema.querystring != null) {
			var props:Dynamic = Reflect.field(schema.querystring, "properties");
			var required:Null<Array<Dynamic>> = Reflect.field(schema.querystring, "required");

			if (props != null) {
				var fieldNames = Reflect.fields(props);
				for (name in fieldNames) {
					var propSchema:Dynamic = Reflect.field(props, name);
					var isRequired = required != null && Lambda.exists(required, item -> Std.string(item) == name);
					var param:Dynamic = {};
					Reflect.setField(param, "name", name);
					Reflect.setField(param, "in", "query");
					Reflect.setField(param, "required", isRequired);
					Reflect.setField(param, "schema", propSchema);
					parameters.push(param);
				}
			}
		}

		if (parameters.length > 0) {
			Reflect.setField(op, "parameters", parameters);
		}

		// Request body
		if (schema != null && schema.body != null) {
			var contentType = "application/json";
			if (schema.consumes != null && schema.consumes.length > 0) {
				contentType = schema.consumes[0];
			}

			var content:Dynamic = {};
			var mediaObj:Dynamic = {};
			Reflect.setField(mediaObj, "schema", schema.body);
			Reflect.setField(content, contentType, mediaObj);

			var requestBody:Dynamic = {};
			Reflect.setField(requestBody, "content", content);
			Reflect.setField(requestBody, "required", true);
			Reflect.setField(op, "requestBody", requestBody);
		}

		// Responses
		if (schema != null && schema.response != null) {
			var responses:Dynamic = {};
			var statusCodes = Reflect.fields(schema.response);

			for (code in statusCodes) {
				var respSchema:Dynamic = Reflect.field(schema.response, code);

				// If the user provided a simple object with just "description",
				// use it directly. Otherwise wrap it as a JSON schema in content.
				var respObj:Dynamic = {};

				var desc:Null<String> = Reflect.field(respSchema, "description");
				if (desc != null) {
					Reflect.setField(respObj, "description", desc);
				} else {
					Reflect.setField(respObj, "description", "Response");
				}

				// If there's a "schema" field, put it under content/application/json
				var innerSchema:Dynamic = Reflect.field(respSchema, "schema");
				if (innerSchema != null) {
					var mediaObj:Dynamic = {};
					Reflect.setField(mediaObj, "schema", innerSchema);
					var content:Dynamic = {};

					var respContentType = "application/json";
					if (schema.produces != null && schema.produces.length > 0) {
						respContentType = schema.produces[0];
					}
					Reflect.setField(content, respContentType, mediaObj);
					Reflect.setField(respObj, "content", content);
				}

				Reflect.setField(responses, code, respObj);
			}

			Reflect.setField(op, "responses", responses);
		} else {
			// Default response
			var responses:Dynamic = {};
			var defaultResp:Dynamic = {};
			Reflect.setField(defaultResp, "description", "Default response");
			Reflect.setField(responses, "200", defaultResp);
			Reflect.setField(op, "responses", responses);
		}

		// Security
		if (schema != null && schema.security != null) {
			Reflect.setField(op, "security", schema.security);
		}

		return op;
	}

}

/** Configuration for the Swagger/OpenAPI plugin. */
typedef SwaggerConfig = {
	/**
	 * Path to serve the OpenAPI JSON spec.
	 * Default: "/docs/openapi.json"
	 */
	?path:String,

	/**
	 * OpenAPI document metadata (info, servers, tags, components).
	 */
	?openapi:OpenApiConfig,

	/**
	 * Tag name to use for hiding routes.
	 * Routes with this tag will be excluded from the spec.
	 */
	?hiddenTag:String,

	/**
	 * If true, routes without any tags are excluded from the spec.
	 * Default: false
	 */
	?hideUntagged:Bool,
};

/** OpenAPI document-level metadata. */
typedef OpenApiConfig = {
	/**
	 * API info object (title, version, description, etc.)
	 * See: https://swagger.io/specification/#info-object
	 */
	?info:Dynamic,

	/**
	 * Server objects for the API.
	 * See: https://swagger.io/specification/#server-object
	 */
	?servers:Array<Dynamic>,

	/**
	 * Tag definitions for grouping operations.
	 * See: https://swagger.io/specification/#tag-object
	 */
	?tags:Array<Dynamic>,

	/**
	 * Reusable components (schemas, security schemes, etc.)
	 * See: https://swagger.io/specification/#components-object
	 */
	?components:Dynamic,
};
