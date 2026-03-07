package w10;

import w10.types.Types;
import w10.types.HttpMethod;

/**
 * Radix-trie HTTP router with parameter extraction.
 *
 * Supports three types of path segments:
 *   - Static:     /users/list       (exact match, highest priority)
 *   - Parametric: /users/:id        (captures named segment)
 *   - Wildcard:   /files/*          (catches everything, lowest priority)
 *
 * The trie is organized by path segments split on '/'. Each node can
 * have static children (exact match), a param child (:name), and a
 * wildcard child (*). During lookup, static children are tried first,
 * then param, then wildcard -- giving correct priority ordering.
 *
 * Example:
 *     var router = new Router();
 *     router.add(Get, "/", handler1);
 *     router.add(Get, "/users/:id", handler2);
 *     router.add(Get, "/files/*", handler3);
 *
 *     var match = router.find(Get, "/users/42");
 *     // match.handler == handler2, match.params == {"id" => "42"}
 */
class Router {
	var root:RouterNode;

	public function new() {
		root = new RouterNode();
	}

	/**
	 * Register a route handler for the given method and path pattern.
	 *
	 * Path patterns:
	 *   "/users"         - static path
	 *   "/users/:id"     - parametric segment (captures "id")
	 *   "/files/*"       - wildcard (captures rest of path)
	 *   "/"              - root path
	 */
	public function add(method:HttpMethod, path:String, entry:RouteEntry):Void {
		var segments = splitPath(path);
		var node = root;

		for (segment in segments) {
			if (segment.charAt(0) == ":") {
				// Parametric segment
				if (node.paramChild == null) {
					node.paramChild = new RouterNode();
				}
				node.paramChild.paramName = segment.substr(1);
				node = node.paramChild;
			} else if (segment == "*") {
				// Wildcard segment (must be last)
				if (node.wildcardChild == null) {
					node.wildcardChild = new RouterNode();
				}
				node = node.wildcardChild;
				break; // wildcard consumes the rest
			} else {
				// Static segment
				var child = node.staticChildren.get(segment);
				if (child == null) {
					child = new RouterNode();
					node.staticChildren.set(segment, child);
				}
				node = child;
			}
		}

		node.setHandler(method, entry);
	}

	/**
	 * Look up a handler for the given method and URL path.
	 * Returns null if no matching route is found.
	 */
	public function find(method:HttpMethod, path:String):Null<RouteMatch> {
		var segments = splitPath(path);
		var params = new Map<String, String>();

		var entry = matchNode(root, segments, 0, method, params);
		if (entry != null) {
			return {entry: entry, params: params};
		}

		return null;
	}

	/**
	 * Recursive matching with backtracking.
	 * Tries static > param > wildcard in priority order.
	 */
	function matchNode(node:RouterNode, segments:Array<String>, index:Int, method:HttpMethod,
			params:Map<String, String>):Null<RouteEntry> {
		// Base case: consumed all segments
		if (index == segments.length) {
			return node.getHandler(method);
		}

		var segment = segments[index];

		// 1. Try static children first (highest priority)
		var staticChild = node.staticChildren.get(segment);
		if (staticChild != null) {
			var result = matchNode(staticChild, segments, index + 1, method, params);
			if (result != null)
				return result;
		}

		// 2. Try parametric child
		if (node.paramChild != null) {
			// Save param value
			var paramName = node.paramChild.paramName;
			params.set(paramName, segment);

			var result = matchNode(node.paramChild, segments, index + 1, method, params);
			if (result != null)
				return result;

			// Backtrack: remove param if this branch didn't match
			params.remove(paramName);
		}

		// 3. Try wildcard child (lowest priority, consumes rest of path)
		if (node.wildcardChild != null) {
			// Capture everything from this segment onward
			var rest = new StringBuf();
			var i = index;
			while (i < segments.length) {
				if (i > index)
					rest.add("/");
				rest.add(segments[i]);
				i++;
			}
			params.set("*", rest.toString());
			return node.wildcardChild.getHandler(method);
		}

		return null;
	}

	/**
	 * Split a URL path into segments, filtering out empty strings.
	 * "/" -> []   (root has zero segments)
	 * "/foo/bar" -> ["foo", "bar"]
	 * "/foo//bar" -> ["foo", "bar"]
	 */
	static function splitPath(path:String):Array<String> {
		var parts = path.split("/");
		var result = new Array<String>();
		for (part in parts) {
			if (part.length > 0) {
				result.push(part);
			}
		}
		return result;
	}
}

/**
 * A single node in the radix trie.
 *
 * Handlers are stored in a fixed-size array indexed by HttpMethod
 * ordinal (0=Get, 1=Post, ..., 6=Options) for O(1) lookup without
 * needing EnumValueMap.
 */
private class RouterNode {
	static inline final METHOD_COUNT = 7;

	/** Static children keyed by exact segment string */
	public var staticChildren:Map<String, RouterNode>;

	/** Parametric child (matches any single segment) */
	public var paramChild:Null<RouterNode>;

	/** Name of the parameter this node captures (for param nodes) */
	public var paramName:String;

	/** Wildcard child (matches everything from here) */
	public var wildcardChild:Null<RouterNode>;

	/** Route entries indexed by HttpMethod ordinal */
	var handlers:Array<Null<RouteEntry>>;

	public function new() {
		staticChildren = new Map<String, RouterNode>();
		paramChild = null;
		paramName = "";
		wildcardChild = null;
		handlers = [null, null, null, null, null, null, null];
	}

	/** Set a route entry for the given HTTP method */
	public function setHandler(method:HttpMethod, entry:RouteEntry):Void {
		handlers[methodIndex(method)] = entry;
	}

	/** Get the route entry for the given HTTP method, or null */
	public function getHandler(method:HttpMethod):Null<RouteEntry> {
		return handlers[methodIndex(method)];
	}

	/** Map HttpMethod enum to array index */
	static inline function methodIndex(m:HttpMethod):Int {
		var idx = Type.enumIndex(m);
		if (idx < 0 || idx >= METHOD_COUNT) {
			return 0;
		}
		return idx;
	}
}
