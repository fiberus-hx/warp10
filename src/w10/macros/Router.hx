package w10.macros;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;

/**
 * Compile-time macros for Warp10 route registration.
 *
 * Inspects handler function signatures and generates wrapper code that
 * automatically extracts route parameters and query parameters from the
 * request with proper type conversion.
 *
 * Parameters that match `:param` segments in the route path are extracted
 * from `ctx.params` (route parameters). Any remaining parameters are
 * extracted from `ctx.query` (query string parameters).
 *
 * Supports both inline lambdas and function references:
 *
 *     // Route param + query param
 *     app.get("/hello/:name", (ctx: Context, name: String, greeting: String) -> {
 *         // name comes from route :name, greeting comes from ?greeting=...
 *         ctx.text('$greeting $name!');
 *     });
 *
 *     // Function reference
 *     app.get("/users/:id", UsersController.show);
 *
 * Supported parameter types: String, Int, Float, Bool, Null<T> wrappers.
 */
class Router {
	/**
	 * Build the expression for a route registration call.
	 *
	 * Called by the macro methods on Warp10 (get, post, put, etc.).
	 * Inspects the handler expression, extracts extra parameters beyond
	 * `ctx: Context`, classifies them as route or query params, and
	 * generates a wrapper that does extraction and type conversion.
	 *
	 * @param ethis       The Warp10 instance expression (macro `this`)
	 * @param method      The HttpMethod variant name (e.g., "Get", "Post")
	 * @param pathExpr    The route path expression (should be a string literal)
	 * @param handlerExpr The handler function expression
	 * @return Expression that calls `_addRoute` with the generated wrapper
	 */
	public static function buildRouteCall(ethis:Expr, method:String, pathExpr:Expr, handlerExpr:Expr):Expr {
		var extraParams = extractHandlerParams(handlerExpr);

		// Classify params as route or query based on the path
		classifyParams(pathExpr, extraParams);

		// Build the HttpMethod enum value expression (e.g., w10.types.HttpMethod.Get)
		var methodExpr = makeMethodExpr(method);

		// If no extra params, pass handler through unchanged (no schema)
		if (extraParams.length == 0) {
			return macro $ethis._addRoute($methodExpr, $pathExpr, $handlerExpr);
		}

		// Generate wrapper that extracts and converts params
		var wrapper = generateWrapper(extraParams, handlerExpr);

		// Generate RouteSchema with JSON Schema for params and querystring
		var schemaExpr = generateRouteSchema(extraParams);

		return macro $ethis._addRoute($methodExpr, $pathExpr, $wrapper, $schemaExpr);
	}

	/**
	 * Build expression for `all()` which registers for every HTTP method.
	 */
	public static function buildAllRouteCall(ethis:Expr, pathExpr:Expr, handlerExpr:Expr):Expr {
		var extraParams = extractHandlerParams(handlerExpr);
		classifyParams(pathExpr, extraParams);

		if (extraParams.length == 0) {
			return macro $ethis._addAllRoutes($pathExpr, $handlerExpr);
		}

		var wrapper = generateWrapper(extraParams, handlerExpr);
		var schemaExpr = generateRouteSchema(extraParams);
		return macro $ethis._addAllRoutes($pathExpr, $wrapper, $schemaExpr);
	}

	/**
	 * Build an expression for an HttpMethod enum value.
	 * Generates a fully-qualified field access to avoid import issues in
	 * the calling context (e.g., `w10.types.HttpMethod.Get`).
	 */
	private static function makeMethodExpr(method:String):Expr {
		var base:Expr = {expr: EConst(CIdent("w10")), pos: Context.currentPos()};
		base = {expr: EField(base, "types"), pos: Context.currentPos()};
		base = {expr: EField(base, "HttpMethod"), pos: Context.currentPos()};
		base = {expr: EField(base, method), pos: Context.currentPos()};
		return base;
	}

	// =========================================================================
	// Parameter extraction from handler signatures
	// =========================================================================

	/**
	 * Extract extra parameters (beyond ctx) from a handler function expression.
	 * Works with both inline lambdas and function references.
	 */
	private static function extractHandlerParams(handlerExpr:Expr):Array<ParamInfo> {
		var args:Array<{name:String, t:Null<ComplexType>}> = null;

		switch (handlerExpr.expr) {
			case EFunction(_, f):
				// Inline lambda or anonymous function
				args = [];
				for (a in f.args) {
					args.push({name: a.name, t: a.type});
				}

			default:
				// Function reference -- resolve its type
				var typed = try {
					Context.typeof(handlerExpr);
				} catch (e:Dynamic) {
					null;
				};

				if (typed != null) {
					args = resolveArgsFromType(typed, handlerExpr.pos);
				}
		}

		if (args == null || args.length == 0) {
			return [];
		}

		// Skip the first argument (ctx: Context)
		var extra:Array<ParamInfo> = [];
		var i = 1;
		while (i < args.length) {
			var arg = args[i];
			var paramType = resolveParamType(arg.t, arg.name, handlerExpr.pos);
			extra.push({name: arg.name, type: paramType, source: SRoute});
			i++;
		}

		return extra;
	}

	/**
	 * Resolve function arguments from a Haxe Type (for function references).
	 */
	private static function resolveArgsFromType(t:Type, pos:Position):Array<{name:String, t:Null<ComplexType>}> {
		switch (t) {
			case TFun(args, _):
				var result:Array<{name:String, t:Null<ComplexType>}> = [];
				for (a in args) {
					result.push({name: a.name, t: a.t.toComplexType()});
				}
				return result;

			case TLazy(f):
				return resolveArgsFromType(f(), pos);

			default:
				return null;
		}
	}

	/**
	 * Determine the ParamType from a ComplexType annotation.
	 */
	private static function resolveParamType(ct:Null<ComplexType>, paramName:String, pos:Position):ParamType {
		if (ct == null) {
			// No type annotation -- default to String
			return PString;
		}

		switch (ct) {
			case TPath(tp):
				// Check for Null<T>
				if (tp.name == "Null" && tp.params != null && tp.params.length == 1) {
					switch (tp.params[0]) {
						case TPType(innerCt):
							var inner = resolveParamType(innerCt, paramName, pos);
							return PNullable(inner);
						default:
					}
				}

				return switch (tp.name) {
					case "String": PString;
					case "Int": PInt;
					case "Float": PFloat;
					case "Bool": PBool;
					default:
						Context.error('Unsupported route parameter type "${tp.name}" for parameter "$paramName". '
							+ "Supported types: String, Int, Float, Bool, Null<T>", pos);
						PString;
				};

			default:
				Context.error('Unsupported route parameter type for "$paramName". '
					+ "Use String, Int, Float, Bool, or Null<T>.", pos);
				return PString;
		}
	}

	// =========================================================================
	// Parameter classification
	// =========================================================================

	/**
	 * Classify handler parameters as route params or query params.
	 *
	 * Parameters whose names match a `:param` segment in the route path
	 * are tagged as route params (extracted from ctx.params). All others
	 * are tagged as query params (extracted from ctx.query).
	 *
	 * If the path is not a string literal, all params default to route params.
	 */
	private static function classifyParams(pathExpr:Expr, params:Array<ParamInfo>):Void {
		if (params.length == 0)
			return;

		// Extract the path string at compile time
		var pathStr:Null<String> = null;
		switch (pathExpr.expr) {
			case EConst(CString(s, _)):
				pathStr = s;
			default:
				// Path is not a string literal -- can't classify, keep all as route
				return;
		}

		// Parse :param segments from the route path
		var routeParams = new Map<String, Bool>();
		var segments = pathStr.split("/");
		for (seg in segments) {
			if (seg.length > 0 && seg.charAt(0) == ":") {
				routeParams.set(seg.substr(1), true);
			}
		}

		// Classify each handler param
		for (p in params) {
			if (p.name == "_")
				continue;

			if (routeParams.exists(p.name)) {
				p.source = SRoute;
			} else {
				// Check for likely typos: if the param name is similar to
				// a route param, it's almost certainly a mistake.
				var closest:Null<String> = null;
				var closestDist = 3; // threshold
				for (rp in routeParams.keys()) {
					var dist = levenshtein(p.name, rp);
					if (dist < closestDist) {
						closestDist = dist;
						closest = rp;
					}
				}

				if (closest != null) {
					Context.error('Handler parameter "${p.name}" does not match any route param in "$pathStr". '
						+ 'Did you mean ":${closest}"?', pathExpr.pos);
				}

				p.source = SQuery;
			}
		}

		// Verify every route :param has a matching handler param
		for (rp in routeParams.keys()) {
			var found = false;
			for (p in params) {
				if (p.name == rp) {
					found = true;
					break;
				}
			}
			if (!found) {
				Context.warning('Route param ":${rp}" in "$pathStr" has no matching handler parameter. '
					+ "It will only be accessible via ctx.params.", pathExpr.pos);
			}
		}
	}

	/**
	 * Compute the Levenshtein edit distance between two strings.
	 * Used at compile time to detect likely typos in param names.
	 */
	private static function levenshtein(a:String, b:String):Int {
		var aLen = a.length;
		var bLen = b.length;

		if (aLen == 0) return bLen;
		if (bLen == 0) return aLen;

		// Use a single-row DP approach
		var prev = new Array<Int>();
		var curr = new Array<Int>();
		prev.resize(bLen + 1);
		curr.resize(bLen + 1);

		var j = 0;
		while (j <= bLen) {
			prev[j] = j;
			j++;
		}

		var i = 1;
		while (i <= aLen) {
			curr[0] = i;
			j = 1;
			while (j <= bLen) {
				var cost = (a.charCodeAt(i - 1) == b.charCodeAt(j - 1)) ? 0 : 1;
				var del = prev[j] + 1;
				var ins = curr[j - 1] + 1;
				var sub = prev[j - 1] + cost;

				// min of three
				var m = del;
				if (ins < m) m = ins;
				if (sub < m) m = sub;
				curr[j] = m;

				j++;
			}

			// Swap rows
			var tmp = prev;
			prev = curr;
			curr = tmp;

			i++;
		}

		return prev[bLen];
	}

	// =========================================================================
	// Wrapper generation
	// =========================================================================

	/**
	 * Generate a wrapper lambda `(ctx: Context) -> Void` that extracts
	 * route and query parameters, converts types, and calls the user's handler.
	 */
	private static function generateWrapper(params:Array<ParamInfo>, handlerExpr:Expr):Expr {
		var stmts:Array<Expr> = [];

		// Generate extraction + conversion for each param
		var callArgs:Array<Expr> = [macro ctx]; // first arg is always ctx

		for (p in params) {
			var paramName = p.name;

			// Pick the source: ctx.params for route params, ctx.query for query params
			var rawExpr = switch (p.source) {
				case SRoute: macro ctx.params.get($v{paramName});
				case SQuery: macro ctx.query.get($v{paramName});
			};

			var convertedExpr = generateConversion(rawExpr, p.type, paramName);

			// var <paramName> = <convertedExpr>;
			stmts.push({
				expr: EVars([
					{
						name: paramName,
						type: null,
						expr: convertedExpr,
						isFinal: true,
					}
				]),
				pos: handlerExpr.pos,
			});

			callArgs.push(macro $i{paramName});
		}

		// Determine if handler is an inline function whose body we can inline,
		// or a reference we need to call
		switch (handlerExpr.expr) {
			case EFunction(_, f):
				// Inline the function body -- the generated local vars have the
				// same names as the lambda params, so the body can reference
				// them directly.
				stmts.push(f.expr);

				return {
					expr: EFunction(FAnonymous, {
						args: [{name: "ctx", type: macro :w10.Context}],
						ret: macro :Void,
						expr: macro $b{stmts},
					}),
					pos: handlerExpr.pos,
				};

			default:
				// Function reference -- call it with extracted args
				stmts.push(macro $handlerExpr($a{callArgs}));

				return {
					expr: EFunction(FAnonymous, {
						args: [{name: "ctx", type: macro :w10.Context}],
						ret: macro :Void,
						expr: macro $b{stmts},
					}),
					pos: handlerExpr.pos,
				};
		}
	}

	// =========================================================================
	// Route schema generation (for OpenAPI)
	// =========================================================================

	/**
	 * Generate a RouteSchema expression with JSON Schema for path and query params.
	 *
	 * Produces an expression like:
	 *   {
	 *       params: {
	 *           type: "object",
	 *           properties: { userId: { type: "integer" }, postId: { type: "integer" } },
	 *           required: ["userId", "postId"],
	 *       },
	 *       querystring: {
	 *           type: "object",
	 *           properties: { q: { type: "string" } },
	 *           required: ["q"],
	 *       },
	 *   }
	 *
	 * Only includes `params` / `querystring` keys if there are params of that source.
	 * Nullable params are omitted from the `required` array.
	 */
	private static function generateRouteSchema(params:Array<ParamInfo>):Expr {
		var pos = Context.currentPos();

		// Separate route params and query params
		var routeParams:Array<ParamInfo> = [];
		var queryParams:Array<ParamInfo> = [];
		for (p in params) {
			switch (p.source) {
				case SRoute:
					routeParams.push(p);
				case SQuery:
					queryParams.push(p);
			}
		}

		var schemaFields:Array<ObjectField> = [];

		if (routeParams.length > 0) {
			schemaFields.push({field: "params", expr: buildJsonSchemaObject(routeParams, pos)});
		}
		if (queryParams.length > 0) {
			schemaFields.push({field: "querystring", expr: buildJsonSchemaObject(queryParams, pos)});
		}

		return {expr: EObjectDecl(schemaFields), pos: pos};
	}

	/**
	 * Build a JSON Schema "object" expression for a list of typed params.
	 *
	 * Returns an expression like:
	 *   {
	 *       type: "object",
	 *       properties: { name: { type: "string" }, age: { type: "integer" } },
	 *       required: ["name", "age"],
	 *   }
	 */
	private static function buildJsonSchemaObject(params:Array<ParamInfo>, pos:Position):Expr {
		var propFields:Array<ObjectField> = [];
		var requiredExprs:Array<Expr> = [];

		for (p in params) {
			// Build the property schema: { type: "string" } etc
			var innerType = p.type;
			var isNullable = false;
			switch (innerType) {
				case PNullable(inner):
					innerType = inner;
					isNullable = true;
				default:
			}

			var typeStr = paramTypeToJsonType(innerType);
			var propSchema:Array<ObjectField> = [{field: "type", expr: macro $v{typeStr}}];
			propFields.push({field: p.name, expr: {expr: EObjectDecl(propSchema), pos: pos}});

			if (!isNullable) {
				requiredExprs.push(macro $v{p.name});
			}
		}

		var objFields:Array<ObjectField> = [];
		objFields.push({field: "type", expr: macro $v{"object"}});
		objFields.push({field: "properties", expr: {expr: EObjectDecl(propFields), pos: pos}});

		if (requiredExprs.length > 0) {
			objFields.push({field: "required", expr: {expr: EArrayDecl(requiredExprs), pos: pos}});
		}

		return {expr: EObjectDecl(objFields), pos: pos};
	}

	/**
	 * Map a ParamType to a JSON Schema type string.
	 */
	private static function paramTypeToJsonType(t:ParamType):String {
		return switch (t) {
			case PString: "string";
			case PInt: "integer";
			case PFloat: "number";
			case PBool: "boolean";
			case PNullable(inner): paramTypeToJsonType(inner);
		};
	}

	// =========================================================================
	// Type conversion generation
	// =========================================================================

	/**
	 * Generate a type conversion expression for a raw string param value.
	 */
	private static function generateConversion(rawExpr:Expr, paramType:ParamType, paramName:String):Expr {
		return switch (paramType) {
			case PString:
				rawExpr;

			case PInt:
				macro Std.parseInt($rawExpr);

			case PFloat:
				macro Std.parseFloat($rawExpr);

			case PBool:
				macro($rawExpr == "true");

			case PNullable(inner):
				// Unique temp var per param to avoid collisions
				var tmpName = '_pv_$paramName';
				var tmpIdent = macro $i{tmpName};
				var innerConv = generateConversion(tmpIdent, inner, paramName);
				var varDecl:Expr = {
					expr: EVars([{name: tmpName, type: null, expr: rawExpr}]),
					pos: rawExpr.pos,
				};
				macro {
					$varDecl;
					if ($tmpIdent != null) $innerConv; else null;
				};
		};
	}
}

/**
 * Where a handler parameter value comes from.
 */
private enum ParamSource {
	/** Route path parameter (from ctx.params) */
	SRoute;

	/** Query string parameter (from ctx.query) */
	SQuery;
}

/**
 * Represents the type of a route parameter for code generation.
 */
private enum ParamType {
	PString;
	PInt;
	PFloat;
	PBool;
	PNullable(inner:ParamType);
}

/**
 * Info about an extra handler parameter (beyond ctx).
 */
private typedef ParamInfo = {
	name:String,
	type:ParamType,
	source:ParamSource,
};
#end
