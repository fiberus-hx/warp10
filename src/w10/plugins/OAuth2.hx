package w10.plugins;

import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.crypto.Sha256;
import w10.Context;
import w10.types.Types;
import w10.types.HttpMethod;
import w10.utils.Crypto;
import w10.plugins.Cookie;

/**
 * OAuth2 authorization code plugin for Warp10.
 *
 * Like @fastify/oauth2: registers start-redirect and callback routes that
 * implement the OAuth2 Authorization Code flow with optional PKCE (S256).
 *
 * Features:
 *   - Authorization Code flow with CSRF state cookie
 *   - PKCE (Proof Key for Code Exchange) with S256 challenge method
 *   - Preset provider configurations (GitHub, Google, Facebook, Discord)
 *   - Token refresh via static helper
 *   - Fiber-suspending token exchange via haxe.Http (HTTPS/TLS)
 *
 * Dependencies: Requires the Cookie plugin to be registered before OAuth2.
 *
 * Usage:
 *
 *     app.register((scope) -> {
 *         scope.use(Cookie.create());
 *         scope.use(OAuth2.create({
 *             name: "github",
 *             credentials: {
 *                 clientId: Sys.getEnv("GITHUB_CLIENT_ID") ?? "demo",
 *                 clientSecret: Sys.getEnv("GITHUB_CLIENT_SECRET") ?? "demo",
 *             },
 *             auth: OAuth2.GITHUB_CONFIGURATION,
 *             startRedirectPath: "/login/github",
 *             callbackUri: "http://localhost:3000/login/github/callback",
 *             scope: "user:email",
 *             pkce: true,
 *             callbackHandler: (ctx) -> {
 *                 var token = OAuth2.getToken(ctx, "github");
 *                 if (token != null)
 *                     ctx.json({logged_in: true});
 *                 else
 *                     ctx.status(401).text("OAuth2 failed");
 *             },
 *         }));
 *     });
 */
class OAuth2 {
	// =========================================================================
	// Preset provider configurations
	// =========================================================================

	/** GitHub OAuth2 endpoints */
	public static var GITHUB_CONFIGURATION:OAuth2Auth = {
		authorizeHost: "https://github.com",
		authorizePath: "/login/oauth/authorize",
		tokenHost: "https://github.com",
		tokenPath: "/login/oauth/access_token",
	};

	/** Google OAuth2 endpoints */
	public static var GOOGLE_CONFIGURATION:OAuth2Auth = {
		authorizeHost: "https://accounts.google.com",
		authorizePath: "/o/oauth2/v2/auth",
		tokenHost: "https://oauth2.googleapis.com",
		tokenPath: "/token",
	};

	/** Facebook OAuth2 endpoints */
	public static var FACEBOOK_CONFIGURATION:OAuth2Auth = {
		authorizeHost: "https://www.facebook.com",
		authorizePath: "/v18.0/dialog/oauth",
		tokenHost: "https://graph.facebook.com",
		tokenPath: "/v18.0/oauth/access_token",
	};

	/** Discord OAuth2 endpoints */
	public static var DISCORD_CONFIGURATION:OAuth2Auth = {
		authorizeHost: "https://discord.com",
		authorizePath: "/oauth2/authorize",
		tokenHost: "https://discord.com",
		tokenPath: "/api/oauth2/token",
	};

	// =========================================================================
	// Plugin factory
	// =========================================================================

	/**
	 * Create an OAuth2 plugin.
	 *
	 * Registers two GET routes:
	 *   1. startRedirectPath -- redirects the user to the provider's authorization URL
	 *   2. callbackPath (derived from callbackUri) -- handles the provider's callback,
	 *      exchanges the authorization code for an access token
	 */
	public static function create(config:OAuth2Config):PluginFn {
		// Validate required config
		if (config.auth == null) {
			throw "OAuth2: 'auth' is required (use a preset like OAuth2.GITHUB_CONFIGURATION or provide custom endpoints)";
		}
		if (config.credentials == null) {
			throw "OAuth2: 'credentials' is required";
		}

		// Derive callback path from callbackUri
		var callbackPath = extractPath(config.callbackUri);

		// Resolve config defaults
		var name = config.name;
		var clientId = config.credentials.clientId;
		var clientSecret = config.credentials.clientSecret;
		var authorizeUrl = config.auth.authorizeHost + config.auth.authorizePath;
		var tokenUrl = config.auth.tokenHost + config.auth.tokenPath;
		var callbackUri = config.callbackUri;
		var scope = config.scope;
		var pkce = config.pkce == true;
		var callbackHandler = config.callbackHandler;
		var generateState = config.generateStateFunction;

		// Cookie names
		var stateCookieName = "oauth2-state-" + name;
		var pkceCookieName = "oauth2-pkce-" + name;

		// Cookie options for state/pkce cookies
		var cookieOpts:CookieOptions = config.cookie != null ? config.cookie : {
			path: "/",
			httpOnly: true,
			sameSite: "Lax",
			maxAge: 600, // 10 minutes
		};

		return (app:w10.Warp10) -> {
			// ---- Start redirect route ----
			app._addRoute(Get, config.startRedirectPath, (ctx:Context) -> {
				handleStartRedirect(ctx, name, clientId, authorizeUrl, callbackUri, scope, pkce, stateCookieName, pkceCookieName, cookieOpts,
					generateState);
			});

			// ---- Callback route ----
			app._addRoute(Get, callbackPath, (ctx:Context) -> {
				handleCallback(ctx, name, clientId, clientSecret, tokenUrl, callbackUri, pkce, stateCookieName, pkceCookieName, cookieOpts,
					callbackHandler);
			});
		};
	}

	// =========================================================================
	// Static helpers
	// =========================================================================

	/**
	 * Get the OAuth2 token from the request context.
	 *
	 * Returns null if the OAuth2 callback hasn't run or token exchange failed.
	 *
	 *     var token = OAuth2.getToken(ctx, "github");
	 *     if (token != null) trace(token.accessToken);
	 */
	public static function getToken(ctx:Context, name:String):Null<OAuth2Token> {
		var raw:Dynamic = ctx.store.get("oauth2Token:" + name);
		if (raw == null) return null;
		return cast raw;
	}

	/**
	 * Refresh an access token using a refresh token.
	 *
	 * Makes a POST request to the provider's token endpoint with
	 * grant_type=refresh_token. This is a standalone helper that can
	 * be called from any handler -- it does not require a Context.
	 *
	 * Returns null if the refresh fails.
	 *
	 *     var newToken = OAuth2.refreshToken(
	 *         OAuth2.GITHUB_CONFIGURATION,
	 *         credentials,
	 *         oldToken.refreshToken
	 *     );
	 */
	public static function refreshToken(auth:OAuth2Auth, credentials:OAuth2Credentials, refreshTokenValue:String):Null<OAuth2Token> {
		var tokenUrl = auth.tokenHost + auth.tokenPath;

		var postBody = buildFormBody([
			{name: "grant_type", value: "refresh_token"},
			{name: "refresh_token", value: refreshTokenValue},
			{name: "client_id", value: credentials.clientId},
			{name: "client_secret", value: credentials.clientSecret},
		]);

		return exchangeToken(tokenUrl, postBody);
	}

	// =========================================================================
	// Internal route handlers
	// =========================================================================

	/**
	 * Handle the start redirect: generate state, optional PKCE, set cookies,
	 * redirect to provider's authorization URL.
	 */
	static function handleStartRedirect(
		ctx:Context,
		name:String,
		clientId:String,
		authorizeUrl:String,
		callbackUri:String,
		scope:Null<String>,
		pkce:Bool,
		stateCookieName:String,
		pkceCookieName:String,
		cookieOpts:CookieOptions,
		generateState:Null<Void->String>
	):Void {
		// Generate state parameter for CSRF protection
		var state:Null<String> = null;
		if (generateState != null) {
			state = generateState();
		} else {
			state = generateRandomHex(32);
		}

		if (state == null) {
			ctx.status(500).text("OAuth2: failed to generate state");
			return;
		}

		// Set state cookie
		Cookie.set(ctx, stateCookieName, state, cookieOpts);

		// Build authorization URL
		var params:Array<{name:String, value:Null<String>}> = [
			{name: "response_type", value: "code"},
			{name: "client_id", value: clientId},
			{name: "redirect_uri", value: callbackUri},
			{name: "state", value: state},
			{name: "scope", value: scope},
		];

		// PKCE: generate code_verifier and code_challenge
		if (pkce) {
			var verifier = generateCodeVerifier();
			if (verifier == null) {
				ctx.status(500).text("OAuth2: failed to generate PKCE verifier");
				return;
			}

			var challenge = computeCodeChallenge(verifier);

			// Store verifier in cookie for use during callback
			Cookie.set(ctx, pkceCookieName, verifier, cookieOpts);

			params.push({name: "code_challenge", value: challenge});
			params.push({name: "code_challenge_method", value: "S256"});
		}

		var url = authorizeUrl + "?" + buildFormBody(params);

		// Redirect to provider
		ctx.redirect(url);
	}

	/**
	 * Handle the callback: validate state, exchange code for token,
	 * store token, call user's callback handler.
	 */
	static function handleCallback(
		ctx:Context,
		name:String,
		clientId:String,
		clientSecret:String,
		tokenUrl:String,
		callbackUri:String,
		pkce:Bool,
		stateCookieName:String,
		pkceCookieName:String,
		cookieOpts:CookieOptions,
		callbackHandler:Null<(ctx:Context) -> Void>
	):Void {
		// Check for error from provider
		var error = ctx.query.get("error");
		if (error != null) {
			var desc = ctx.query.get("error_description");
			var msg = "OAuth2 error: " + error;
			if (desc != null) msg = msg + " - " + desc;
			ctx.status(400).json({error: "oauth2_error", message: msg});
			return;
		}

		// Get authorization code
		var code = ctx.query.get("code");
		if (code == null) {
			ctx.status(400).json({error: "oauth2_error", message: "Missing authorization code"});
			return;
		}

		// Validate state
		var queryState = ctx.query.get("state");
		var cookieState = Cookie.get(ctx, stateCookieName);

		if (queryState == null || cookieState == null) {
			ctx.status(403).json({error: "oauth2_state_mismatch", message: "Missing state parameter or cookie"});
			return;
		}

		var queryStateBytes = Bytes.ofString(queryState);
		var cookieStateBytes = Bytes.ofString(cookieState);
		if (!Crypto.constantTimeEqual(queryStateBytes, cookieStateBytes)) {
			ctx.status(403).json({error: "oauth2_state_mismatch", message: "State parameter does not match cookie"});
			return;
		}

		// Clear state cookie
		Cookie.clear(ctx, stateCookieName, {path: cookieOpts.path});

		// Build token exchange POST body
		var tokenParams:Array<{name:String, value:Null<String>}> = [
			{name: "grant_type", value: "authorization_code"},
			{name: "code", value: code},
			{name: "redirect_uri", value: callbackUri},
			{name: "client_id", value: clientId},
			{name: "client_secret", value: clientSecret},
		];

		// PKCE: include code_verifier
		if (pkce) {
			var verifier = Cookie.get(ctx, pkceCookieName);
			if (verifier == null) {
				ctx.status(400).json({error: "oauth2_pkce_error", message: "Missing PKCE verifier cookie"});
				return;
			}
			tokenParams.push({name: "code_verifier", value: verifier});

			// Clear PKCE cookie
			Cookie.clear(ctx, pkceCookieName, {path: cookieOpts.path});
		}

		var postBody = buildFormBody(tokenParams);

		// Exchange authorization code for token
		var token = exchangeToken(tokenUrl, postBody);

		// Store token in context (even if null, so callback can check)
		if (token != null) {
			ctx.store.set("oauth2Token:" + name, token);
		}

		// Call user's callback handler or default response
		if (callbackHandler != null) {
			callbackHandler(ctx);
		} else {
			// Default: return token info as JSON
			if (token != null) {
				ctx.json({
					accessToken: token.accessToken,
					tokenType: token.tokenType,
					expiresIn: token.expiresIn,
					scope: token.scope,
					hasRefreshToken: token.refreshToken != null,
				});
			} else {
				ctx.status(502).json({error: "oauth2_token_error", message: "Token exchange failed"});
			}
		}
	}

	// =========================================================================
	// Token exchange
	// =========================================================================

	/**
	 * Exchange credentials at the token endpoint via HTTP POST.
	 *
	 * Uses haxe.Http which on fiberus is fiber-suspending (io_uring backed).
	 * Returns null if the request fails or the response can't be parsed.
	 */
	static function exchangeToken(tokenUrl:String, postBody:String):Null<OAuth2Token> {
		var http = new sys.Http(tokenUrl);
		http.setHeader("Content-Type", "application/x-www-form-urlencoded");
		http.setHeader("Accept", "application/json");
		http.setPostData(postBody);

		var responseData:Null<String> = null;
		var errorMsg:Null<String> = null;

		http.onData = (data:String) -> {
			responseData = data;
		};
		http.onError = (err:String) -> {
			errorMsg = err;
		};

		// request(true) = POST, synchronous (fiber-suspending on fiberus)
		try {
			http.request(true);
		} catch (e:Dynamic) {
			// On HTTP errors (status >= 400), sys.Http throws.
			// The response bytes may still be available.
			if (http.responseBytes != null) {
				responseData = http.responseBytes.toString();
			}
			if (responseData == null) return null;
		}

		// If we got an error callback but also have response data from
		// the error response body, try to parse it anyway (some providers
		// return JSON error details with 4xx status codes).
		if (responseData == null && errorMsg != null) {
			// Check if the error response bytes are available
			if (http.responseBytes != null) {
				responseData = http.responseBytes.toString();
			}
			if (responseData == null) return null;
		}

		if (responseData == null) return null;

		return parseTokenResponse(responseData);
	}

	/**
	 * Parse a JSON token response from the provider.
	 *
	 * Handles the standard OAuth2 token response format:
	 *   { "access_token": "...", "token_type": "...", ... }
	 *
	 * Also handles snake_case variants that most providers use.
	 */
	static function parseTokenResponse(data:String):Null<OAuth2Token> {
		var json:Dynamic = null;
		try {
			json = haxe.Json.parse(data);
		} catch (e:Dynamic) {
			return null;
		}

		if (json == null) return null;

		// access_token is required
		var accessToken:Dynamic = Reflect.field(json, "access_token");
		if (accessToken == null) return null;

		var tokenType:Dynamic = Reflect.field(json, "token_type");
		var refreshToken:Dynamic = Reflect.field(json, "refresh_token");
		var expiresIn:Dynamic = Reflect.field(json, "expires_in");
		var scope:Dynamic = Reflect.field(json, "scope");

		var token:OAuth2Token = {
			accessToken: Std.string(accessToken),
			tokenType: tokenType != null ? Std.string(tokenType) : "Bearer",
			refreshToken: refreshToken != null ? Std.string(refreshToken) : null,
			expiresIn: expiresIn != null ? Std.parseInt(Std.string(expiresIn)) : null,
			scope: scope != null ? Std.string(scope) : null,
		};

		return token;
	}

	// =========================================================================
	// PKCE helpers
	// =========================================================================

	/**
	 * Generate a PKCE code_verifier.
	 *
	 * 32 random bytes → Base64 URL-safe (no padding) = 43 characters.
	 * Meets RFC 7636 requirement of 43-128 characters.
	 */
	static function generateCodeVerifier():Null<String> {
		var bytes = Crypto.randomBytes(32);
		if (bytes == null) return null;
		return Base64.urlEncode(bytes);
	}

	/**
	 * Compute PKCE code_challenge from code_verifier using S256.
	 *
	 * code_challenge = BASE64URL(SHA256(code_verifier))
	 */
	static function computeCodeChallenge(verifier:String):String {
		var verifierBytes = Bytes.ofString(verifier);
		var hash = Sha256.make(verifierBytes);
		return Base64.urlEncode(hash);
	}

	// =========================================================================
	// Utility helpers
	// =========================================================================

	/**
	 * Generate a random hex string (n random bytes → 2n hex chars).
	 */
	static function generateRandomHex(numBytes:Int):Null<String> {
		var bytes = Crypto.randomBytes(numBytes);
		return bytes != null ? bytes.toHex() : null;
	}

	/**
	 * Build a URL-encoded form body string from key-value pairs.
	 *
	 * Each key and value is URL-encoded per RFC 3986. Pairs are
	 * joined with `&`. Null values are skipped.
	 */
	static function buildFormBody(params:Array<{name:String, value:Null<String>}>):String {
		var buf = new StringBuf();
		var first = true;
		for (p in params) {
			if (p.value == null) continue;
			if (!first) buf.add("&");
			buf.add(StringTools.urlEncode(p.name));
			buf.add("=");
			buf.add(StringTools.urlEncode(p.value));
			first = false;
		}
		return buf.toString();
	}

	/**
	 * Extract the path component from a full URI.
	 *
	 * "http://localhost:3000/login/github/callback" → "/login/github/callback"
	 * "https://example.com/oauth/cb?foo=bar" → "/oauth/cb"
	 */
	static function extractPath(uri:String):String {
		// Skip scheme
		var idx = uri.indexOf("://");
		if (idx >= 0) {
			uri = uri.substring(idx + 3);
		}

		// Find start of path
		var slashIdx = uri.indexOf("/");
		if (slashIdx < 0) return "/";

		var path = uri.substring(slashIdx);

		// Strip query string
		var qIdx = path.indexOf("?");
		if (qIdx >= 0) {
			path = path.substring(0, qIdx);
		}

		// Strip fragment
		var hashIdx = path.indexOf("#");
		if (hashIdx >= 0) {
			path = path.substring(0, hashIdx);
		}

		return path;
	}
}

// =============================================================================
// Configuration typedefs
// =============================================================================

/** OAuth2 client credentials. */
typedef OAuth2Credentials = {
	/** The OAuth2 client ID (from provider's developer console) */
	clientId:String,

	/** The OAuth2 client secret (from provider's developer console) */
	clientSecret:String,
};

/** OAuth2 provider authorization/token endpoints. */
typedef OAuth2Auth = {
	/** Authorization endpoint host (e.g. "https://github.com") */
	authorizeHost:String,

	/** Authorization endpoint path (e.g. "/login/oauth/authorize") */
	authorizePath:String,

	/** Token endpoint host (e.g. "https://github.com") */
	tokenHost:String,

	/** Token endpoint path (e.g. "/login/oauth/access_token") */
	tokenPath:String,
};

/** Configuration for the OAuth2 plugin. */
typedef OAuth2Config = {
	/** Plugin instance name (e.g. "github"). Used for store keys and cookie names. */
	name:String,

	/** OAuth2 client credentials */
	credentials:OAuth2Credentials,

	/** Provider endpoint configuration. Use a preset like OAuth2.GITHUB_CONFIGURATION
	 *  or provide custom authorize/token URLs. */
	?auth:OAuth2Auth,

	/** URL path for the start-redirect route (e.g. "/login/github"). */
	startRedirectPath:String,

	/** Full callback URI including scheme and host (e.g. "http://localhost:3000/login/github/callback").
	 *  The path portion is extracted and registered as a route. The full URI is sent
	 *  as redirect_uri to the provider. */
	callbackUri:String,

	/** Space-separated OAuth2 scopes (e.g. "user:email repo"). */
	?scope:String,

	/** Custom handler called after the token exchange completes.
	 *  If not provided, the default handler returns the token as JSON.
	 *  Use OAuth2.getToken(ctx, name) to retrieve the token. */
	?callbackHandler:(ctx:Context) -> Void,

	/** Cookie options for the state and PKCE cookies.
	 *  Defaults to: path="/", httpOnly=true, sameSite="Lax", maxAge=600. */
	?cookie:CookieOptions,

	/** Enable PKCE (Proof Key for Code Exchange) with S256 challenge method.
	 *  Recommended for all clients, required by some providers. Default: false. */
	?pkce:Bool,

	/** Custom state generation function. If not provided, generates
	 *  32 random bytes as a hex string via /dev/urandom. */
	?generateStateFunction:Void->String,
};

/** OAuth2 token response from the provider. */
typedef OAuth2Token = {
	/** The access token issued by the provider */
	accessToken:String,

	/** Token type, typically "Bearer" */
	tokenType:String,

	/** The refresh token (may be null if provider doesn't issue one) */
	?refreshToken:Null<String>,

	/** Token lifetime in seconds (may be null) */
	?expiresIn:Null<Int>,

	/** Granted scopes (may differ from requested scopes) */
	?scope:Null<String>,
};
