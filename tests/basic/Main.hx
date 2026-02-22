import w10.*;
import w10.types.HttpStatus;
import w10.types.Hook.HookPoint;

import w10.plugins.Compress;
import w10.plugins.Cors;
import w10.plugins.StaticFiles;
import w10.plugins.Cookie;
import w10.plugins.FormBody;
import w10.plugins.Multipart;
import w10.plugins.Csrf;
import w10.plugins.OAuth2;
import w10.plugins.Sse;
import w10.plugins.Swagger;
import w10.plugins.SwaggerUi;
import w10.types.HttpMethod;

class Main {
    static function main() {
        final app = new Warp10({
            logging: true
        });

        // Global compression (before other plugins so all responses are compressed)
        app.use(Compress.create({threshold: 1024}));

        // CORS -- allow all origins (global, applies to every route)
        app.use(Cors.create({origin: "*"}));

        // OpenAPI spec endpoint -- auto-discovers all routes
        app.register(Swagger.create({
            path: "/docs/openapi.json",
            openapi: {
                info: {
                    title: "Warp10 Demo API",
                    description: "Demo application for the Warp10 web framework",
                    version: "0.1.0",
                },
                servers: [{url: "http://localhost:8080"}],
                tags: [
                    {name: "general", description: "General endpoints"},
                    {name: "users", description: "User operations"},
                    {name: "search", description: "Search operations"},
                    {name: "admin", description: "Admin operations"},
                    {name: "csrf", description: "CSRF demo endpoints"},
                    {name: "cookies", description: "Cookie demo endpoints"},
                    {name: "auth", description: "Authentication"},
                    {name: "sse", description: "Server-Sent Events"},
                ],
            },
        }));

        // Swagger UI -- interactive API documentation page
        app.register(SwaggerUi.create({
            title: "Warp10 Demo API",
        }));

        // Static file plugin -- serves files from ./public under /static/
        final publicDir = sys.FileSystem.fullPath("public");
        app.register(StaticFiles.create({root: publicDir, prefix: "/static"}));

        // Simple text response
        app.get("/", ctx -> ctx.text("Welcome to Warp10 🚀"));

        // Route with typed parameter (macro extracts `name` from ctx.params)
        app.get("/hello/:name", (ctx:Context, name:String) -> {
            ctx.log.info("greeting user", {name: name});
            ctx.text('Hello $name!');
        });

        // JSON response
        app.get("/json", ctx -> ctx.json({message: "ok", count: 42}));

        // Multiple typed params (Int conversion is automatic)
        app.get("/users/:userId/posts/:postId", (ctx:Context, userId:Int, postId:Int) -> {
            ctx.json({userId: userId, postId: postId});
        });

        // Query string access (macro extracts `q` from ctx.query automatically)
        app.get("/search", (ctx:Context, q:String) -> {
            ctx.json({query: q});
        });

        // POST route
        app.post("/echo", (ctx) -> {
            final body = ctx.req.body;
            if (body != null) {
                ctx.bytes(body, "application/octet-stream");
            } else {
                ctx.status(HttpStatus.BAD_REQUEST).text("No body");
            }
        });

        // Enrich routes with OpenAPI metadata via describe()
        app.describe(Get, "/", {
            summary: "Welcome page",
            tags: ["general"],
        });
        app.describe(Get, "/hello/:name", {
            summary: "Greet a user by name",
            tags: ["general"],
            response: {"200": {description: "Greeting message"}},
        });
        app.describe(Get, "/json", {
            summary: "Sample JSON response",
            tags: ["general"],
        });
        app.describe(Get, "/users/:userId/posts/:postId", {
            summary: "Get a specific post by a specific user",
            tags: ["users"],
            response: {"200": {description: "User post data", schema: {type: "object", properties: {userId: {type: "integer"}, postId: {type: "integer"}}}}},
        });
        app.describe(Get, "/search", {
            summary: "Search with query string",
            tags: ["search"],
            response: {"200": {description: "Search results"}},
        });
        app.describe(Post, "/echo", {
            summary: "Echo request body",
            tags: ["general"],
            body: {type: "string"},
            consumes: ["application/octet-stream"],
            response: {"200": {description: "Echoed body"}, "400": {description: "No body provided"}},
        });

        // Nested routes with prefix
        final api = app.route("/api/v1");
        api.get("/status", (ctx) -> {
            ctx.json({status: "running", version: "0.1.0"});
        });
        api.get("/users", (ctx) -> {
            ctx.json({users: []});
        });

        // Scoped plugin demo -- admin routes with auth hook
        // The PreHandler hook only applies to routes inside this register() block
        app.register((admin) -> {
            admin.addHook(PreHandler, (ctx) -> {
                final token = ctx.getHeader("X-Admin-Token");
                if (token != "secret") {
                    ctx.status(HttpStatus.UNAUTHORIZED).json({error: "Admin token required"});
                }
            });

            final adminApi = admin.route("/admin");
            adminApi.get("/dashboard", (ctx) -> {
                ctx.json({page: "admin dashboard", user: "admin"});
            });
            adminApi.get("/settings", (ctx) -> {
                ctx.json({theme: "dark", notifications: true});
            });
        });

        // CSRF-protected routes
        // Cookie + FormBody plugins are required before CSRF.
        // register() creates an encapsulated scope; use() applies plugins
        // directly so routes registered within inherit their hooks.
        app.register((scope) -> {
            scope.use(Cookie.create({}));
            scope.use(FormBody.create({}));
            scope.use(Multipart.create({limits: {fileSize: 5 * 1024 * 1024}}));
            scope.use(Csrf.create({}));

            scope.get("/csrf/form", (ctx) -> {
                // Token is in ctx.store and X-CSRF-Token response header
                var token:Dynamic = ctx.store.get("csrfToken");
                var tokenStr = token != null ? Std.string(token) : "";
                ctx.html('<html><body>'
                    + '<h1>CSRF Demo</h1>'
                    + '<p>Token: <code>' + tokenStr + '</code></p>'
                    + '<form method="POST" action="/csrf/submit">'
                    + '<input type="hidden" name="_csrf" value="' + tokenStr + '">'
                    + '<button type="submit">Submit</button>'
                    + '</form>'
                    + '</body></html>');
            });

            scope.post("/csrf/submit", (ctx) -> {
                ctx.json({success: true, message: "CSRF validation passed"});
            });

            scope.get("/upload", (ctx) -> {
                var token:Dynamic = ctx.store.get("csrfToken");
                var tokenStr = token != null ? Std.string(token) : "";
                ctx.html('<html><body>'
                    + '<h1>File Upload</h1>'
                    + '<p>Token: <code>' + tokenStr + '</code></p>'
                    + '<form method="POST" action="/upload" enctype="multipart/form-data">'
                    + '<input type="text" name="description" placeholder="Description">'
                    + '<br><br>'
                    + '<input type="file" name="file">'
                    + '<input type="hidden" name="_csrf" value="' + tokenStr + '">'
                    + '<br><br>'
                    + '<button type="submit">Upload</button>'
                    + '</form>'
                    + '</body></html>');
            });

            scope.post("/upload", (ctx) -> {
                var parts = Multipart.getParts(ctx);
                if (parts != null) {
                    var files = new Array<Dynamic>();
                    for (part in parts) {
                        files.push({
                            fieldname: part.fieldname,
                            filename: part.filename,
                            contentType: part.contentType,
                            size: part.size,
                        });
                    }
                    // Also show text fields from formBody store
                    var desc = FormBody.get(ctx, "description");
                    ctx.json({
                        parts: files,
                        description: desc,
                    });
                } else {
                    ctx.status(HttpStatus.BAD_REQUEST).json({error: "No multipart data"});
                }
            });
        });

        // Cookie demo (standalone, without CSRF)
        app.register((cookieDemo) -> {
            cookieDemo.use(Cookie.create({}));

            cookieDemo.get("/cookie/set", (ctx) -> {
                Cookie.set(ctx, "demo", "hello-warp10", {path: "/", maxAge: 3600});
                ctx.json({message: "Cookie set", name: "demo", value: "hello-warp10"});
            });

            cookieDemo.get("/cookie/get", (ctx) -> {
                var value = Cookie.get(ctx, "demo");
                ctx.json({name: "demo", value: value});
            });

            cookieDemo.get("/cookie/clear", (ctx) -> {
                Cookie.clear(ctx, "demo", {path: "/"});
                ctx.json({message: "Cookie cleared", name: "demo"});
            });
        });

        // OAuth2 demo (GitHub)
        // Uses environment variables for credentials, falls back to dummy values.
        // To test: set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET, then visit /login/github
        app.register((oauth) -> {
            oauth.use(Cookie.create());
            oauth.use(OAuth2.create({
                name: "github",
                credentials: {
                    clientId: Sys.getEnv("GITHUB_CLIENT_ID") ?? "dummy-client-id",
                    clientSecret: Sys.getEnv("GITHUB_CLIENT_SECRET") ?? "dummy-client-secret",
                },
                auth: OAuth2.GITHUB_CONFIGURATION,
                startRedirectPath: "/login/github",
                callbackUri: "http://localhost:8080/login/github/callback",
                scope: "user:email",
                pkce: true,
                callbackHandler: (ctx) -> {
                    var token = OAuth2.getToken(ctx, "github");
                    if (token != null) {
                        ctx.json({
                            logged_in: true,
                            token_type: token.tokenType,
                            has_refresh_token: token.refreshToken != null,
                        });
                    } else {
                        ctx.status(401).json({error: "OAuth2 authentication failed"});
                    }
                },
            }));
        });

        // SSE demo -- streams a counter event every second
        // Test with: curl -N http://localhost:8080/events
        app.get("/events", (ctx) -> {
            Sse.stream(ctx, {heartbeatInterval: 15000}, (send) -> {
                var id = 0;
                while (send({data: '{"count":${Std.string(id)},"time":"${Date.now().toString()}"}', event: "tick", id: Std.string(id)})) {
                    id++;
                    fiberus.io.Timer.sleep(1000);
                }
            });
        });

        // SSE demo page -- HTML with EventSource client
        app.get("/sse", (ctx) -> {
            ctx.html('<html><head><title>SSE Demo</title></head><body>'
                + '<h1>Server-Sent Events Demo</h1>'
                + '<div id="events" style="font-family:monospace;white-space:pre"></div>'
                + '<script>'
                + 'var es = new EventSource("/events");'
                + 'var div = document.getElementById("events");'
                + 'es.addEventListener("tick", function(e) {'
                + '  div.textContent += e.data + "\\n";'
                + '});'
                + 'es.onerror = function() { div.textContent += "[disconnected]\\n"; };'
                + '</script>'
                + '</body></html>');
        });

        // Redirect
        app.get("/old", ctx -> ctx.redirect("/"));

        // Custom status
        app.get("/teapot", ctx -> ctx.status(418).text("I'm a teapot"));

        // GC stats
        app.get("/gc", ctx -> ctx.text(fiberus.GC.statsString()));

        // Template with typed params
        app.get("/template/:name/:age", (ctx:Context, name:String, age:Int) -> {
            var user:User = {
                name: name,
                age: age
            };
            var sample =
            '<html>
                <body>
                    <p>::name:: - ::age::</p>
                </body>
            </html>';
            var template = new haxe.Template(sample);
            var output = template.execute(user);
            ctx.html(output);
        });

        // Start server
        app.listen({port: 8080, host: "localhost"}, () -> {
            trace("Warp10 listening on http://localhost:8080");
            trace("Try:");
            trace("  curl http://localhost:8080/");
            trace("  curl http://localhost:8080/hello/world");
            trace("  curl http://localhost:8080/json");
            trace("  curl http://localhost:8080/users/42/posts/7");
            trace('  curl "http://localhost:8080/search?q=fiberus"');
            trace("  curl http://localhost:8080/api/v1/status");
            trace("  curl -X POST -d 'hello' http://localhost:8080/echo");
            trace("  curl http://localhost:8080/template/Alice/30");
            trace("  curl http://localhost:8080/static/index.html");
            trace("  curl http://localhost:8080/static/style.css");
            trace("  curl http://localhost:8080/admin/dashboard                  # 401 (no token)");
            trace("  curl -H 'X-Admin-Token: secret' http://localhost:8080/admin/dashboard  # 200");
            trace("  curl -v http://localhost:8080/csrf/form          # GET sets cookie + token");
            trace("  curl -v http://localhost:8080/cookie/set         # Set a cookie");
            trace("  curl -v http://localhost:8080/cookie/get         # Read cookie back");
            trace("  curl -v http://localhost:8080/upload             # Multipart upload form");
            trace("  curl -v http://localhost:8080/login/github       # OAuth2 start (redirects to GitHub)");
            trace("  curl -N  http://localhost:8080/events            # SSE event stream");
            trace("  open     http://localhost:8080/sse               # SSE demo page in browser");
            trace("  curl     http://localhost:8080/docs/openapi.json  # OpenAPI 3.0.3 spec");
            trace("  open     http://localhost:8080/docs               # Swagger UI");
            trace("  curl -v -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: GET' http://localhost:8080/json  # CORS preflight");
        });
    }
}

@:structInit
class User {
    var name:String;
    var age:Int;
}
