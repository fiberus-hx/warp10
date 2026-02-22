package w10.types;

import w10.Context;

/**
 * Hook function signature.
 *
 * All hooks receive a Context and return Void.
 * To short-circuit the request lifecycle (e.g. early auth rejection,
 * static file response), send a response via ctx.text()/json()/etc.
 * The hook chain stops as soon as ctx.res.sent becomes true.
 */
typedef HookFn = (ctx:Context) -> Void;

/**
 * Supported hook points in the request lifecycle.
 *
 * Execution order for a matched route:
 *   1. OnRequest  — after parse, before route lookup
 *   2. PreHandler — after route match + param population, before handler
 *   3. OnResponse — after response sent (logging, metrics, cleanup)
 *
 * OnRequest and PreHandler can short-circuit by sending a response.
 * OnResponse always runs (cannot short-circuit).
 */
enum HookPoint {
	/** Runs after request parsing, before route lookup.
	 *  The Context has req/res but route params are NOT yet populated. */
	OnRequest;

	/** Runs after a route match is found and params are populated,
	 *  but before the route handler executes. */
	PreHandler;

	/** Runs after the response has been sent to the client.
	 *  Cannot modify the response. Useful for logging, metrics, cleanup. */
	OnResponse;
}
