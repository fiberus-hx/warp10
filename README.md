
![Alt text](./assets/header_wide.png "a title")

---
> [!CAUTION]
> This is alpha software. Things will change. This is not production ready.
---

**Blazing-fast web framework for Fiberus -- the fiber-native Haxe target**

W10 is a high-performance HTTP framework designed from the ground up for the [Fiberus](https://github.com/fiberus-hx/fiberus) runtime. It lets you write clean, synchronous-style handlers while leveraging Fiberus' cooperative fibers and io_uring integration to handle thousands of concurrent connections with minimal overhead.

Inspired by **Go Fiber** (for its elegant, zero-async API) and **Fastify** (for its powerful plugin/hook system), Warp10 gives you the best of both worlds:
- **Go-like simplicity** -- handlers look blocking but suspend automatically on I/O
- **Fastify-like extensibility** -- lifecycle hooks, encapsulated plugins, decorators

## Features

- **Fiber-per-connection model** -- each request runs in its own fiber via Fiberus + io_uring; no thread blocking
- **Synchronous-style API** -- no `async`/`await`, no callbacks, no promises
- **Multi-threaded accept** -- `SO_REUSEPORT` distributes connections across worker threads at the kernel level
- **HTTP/1.1 keep-alive** -- persistent connections with configurable timeouts and max-requests limits
- **Radix-trie router** -- fast path matching with static, parametric (`:id`), and wildcard (`*`) segments
- **Compile-time typed parameters** -- handler parameters are extracted from route segments and query strings at compile time via macros, with automatic type conversion and compile-time validation
- **Plugin system** -- Fastify-style encapsulated scoping (`register`) and flat application (`use`) with three lifecycle hooks: `OnRequest`, `PreHandler`, `OnResponse`
- **OpenAPI generation** -- route parameter schemas are auto-generated from handler type signatures; enrich with `describe()` for full OpenAPI 3.0.3 specs
- **11 built-in plugins** -- CORS, compression, cookies, CSRF, form parsing, multipart uploads, OAuth2, SSE, Swagger/SwaggerUI, and static files
- **Structured logging** -- Pino-inspired JSON logger with child bindings and monotonic timestamps

---
> [!WARNING]
> Fibers can move across threads! Pay attention dont write the same mutable data from multiple fibers/threads!
---
> [!IMPORTANT]
> fiberus is currently Linux-only! Other platforms will follow eventually

## Prerequisites

- **[Fiberus](https://github.com/fiberus-hx/fiberus)** runtime (custom Haxe target compiling to C)
- **[Haxe](https://github.com/fiberus-hx/haxe/tree/fiberus)** custom compiler branch that includes fiberus' codegen
- **Linux** with io_uring support (kernel 5.1+)

## Quick Start

```hxml
-D multithreaded
-D iouring
--fiberus bin
-cp path/to/warp10/src
-main Main
-dce full
```

```haxe
import w10.*;
import w10.types.HttpStatus;
import w10.types.Hook.HookPoint;
import w10.plugins.Cookie;
import w10.plugins.StaticFiles;

class Main {
    static function main() {
        final app = new Warp10({logging: true});

        // Static files from ./public under /static/
        final publicDir = sys.FileSystem.fullPath("public");
        app.register(StaticFiles.create({root: publicDir, prefix: "/static"}));

        // Simple text response
        app.get("/", ctx -> ctx.text("Welcome to Warp10"));

        // Typed route parameter -- macro extracts `name` from :name at compile time
        app.get("/hello/:name", (ctx:Context, name:String) -> {
            ctx.log.info("greeting user", {name: name});
            ctx.text('Hello $name!');
        });

        // JSON response with multiple typed params (Int conversion is automatic)
        app.get("/users/:userId/posts/:postId", (ctx:Context, userId:Int, postId:Int) -> {
            ctx.json({userId: userId, postId: postId});
        });

        // Query string params -- macro extracts `q` from ?q= automatically
        app.get("/search", (ctx:Context, q:String) -> {
            ctx.json({query: q});
        });

        // Nested routes with prefix
        final api = app.route("/api/v1");
        api.get("/status", ctx -> ctx.json({status: "running", version: "0.1.0"}));
        api.get("/users", ctx -> ctx.json({users: []}));

        // Scoped plugin -- admin routes with auth hook (only applies within this scope)
        app.register((admin) -> {
            admin.addHook(PreHandler, (ctx) -> {
                final token = ctx.getHeader("X-Admin-Token");
                if (token != "secret") {
                    ctx.status(HttpStatus.UNAUTHORIZED).json({error: "Admin token required"});
                }
            });

            final adminApi = admin.route("/admin");
            adminApi.get("/dashboard", ctx -> ctx.json({page: "admin dashboard"}));
        });

        // Cookie demo
        app.register((scope) -> {
            scope.use(Cookie.create({}));
            scope.get("/cookie/set", (ctx) -> {
                Cookie.set(ctx, "demo", "hello-warp10", {path: "/", maxAge: 3600});
                ctx.json({message: "Cookie set"});
            });
        });

        // Start server
        app.listen({port: 8080, host: "localhost"}, () -> {
            trace("Warp10 listening on http://localhost:8080");
        });
    }
}
```

## Plugins

| Plugin | Description |
|---|---|
| **Compress** | Response compression (deflate) with configurable threshold and compression level |
| **CORS** | Cross-Origin Resource Sharing with preflight handling, origin whitelists, regex/function matchers, and credentials support |
| **Cookie** | Parses `Cookie` headers; provides `get()`, `set()`, `clear()` helpers with all standard cookie attributes |
| **CSRF** | Double Submit Cookie pattern with HMAC-SHA256 token generation and validation |
| **CORS** | CORS (Cross-Origin Resource Sharing) |
| **FormBody** | Parses `application/x-www-form-urlencoded` request bodies with URL decoding |
| **Multipart** | Full `multipart/form-data` boundary parser for file uploads with configurable size limits |
| **OAuth2** | Authorization Code flow with PKCE (S256); preset configs for GitHub, Google, Facebook, Discord |
| **SSE** | Server-Sent Events streaming with managed `stream()` API, background heartbeat fibers, and connection state detection |
| **Swagger** | OpenAPI 3.0.3 spec generator; auto-discovers routes and merges schemas from `describe()` |
| **SwaggerUI** | Serves an interactive Swagger UI documentation page |
| **StaticFiles** | Serves static files from a directory under a configurable URL prefix |

Plugins are applied via `register()` (encapsulated scope) or `use()` (flat, current scope):

```haxe
// Global -- applies to all routes
app.use(Cors.create({origin: "*"}));

// Encapsulated -- hooks only apply to routes inside this block
app.register(Swagger.create({path: "/docs/openapi.json", openapi: { ... }}));

// Flat -- hooks apply to all routes in the current scope
scope.use(Cookie.create({}));
scope.use(Csrf.create({}));
```

## Architecture

```
Request lifecycle:

  accept() ──> spawn fiber ──> recv + parse HTTP
                                     │
                                     v
                              Router.find()  (radix trie lookup)
                                     │
                           ┌─────────┴─────────┐
                           │  OnRequest hooks   │  ← can short-circuit
                           ├───────────────────-┤
                           │  PreHandler hooks  │  ← can short-circuit
                           ├────────────────────┤
                           │  Route handler     │
                           ├────────────────────┤
                           │  OnResponse hooks  │  ← always runs
                           └────────────────────┘
                                     │
                              keep-alive? ──yes──> loop back to recv
                                     │
                                    no
                                     │
                                  close()
```

The server spawns multiple accept threads using `SO_REUSEPORT` for kernel-level load balancing. Each accepted connection gets its own lightweight fiber. All socket I/O (`accept`, `recv`, `send`, `poll`) fiber-suspends via io_uring rather than blocking an OS thread.

Hooks are **scoped**: routes registered inside a `register()` block carry exactly the hooks that were active in that scope at registration time, matching Fastify's encapsulation model.

## Configuration

Pass a `ServerConfig` to the `Warp10` constructor:

```haxe
final app = new Warp10({
    serviceName: "my-api",         // logger service name (default: "warp10")
    acceptThreads: 4,              // accept thread count (default: CPU core count)
    maxHeaderSize: 8192,           // max header size in bytes (default: 8192)
    recvBufferSize: 4096,          // receive buffer size (default: 4096)
    keepAliveTimeout: 15000,       // keep-alive timeout in ms (default: 15000)
    maxRequestsPerConnection: 1000,// max requests per connection (default: 1000)
    backlog: 4096,                 // listen backlog (default: 4096)
    logging: true,                 // enable structured JSON logging (default: false)
});
```

## Status

**Alpha** -- core framework, router, plugin system, and all listed plugins are implemented and functional. The API surface may change before a stable release.

### What works today
- Multi-threaded HTTP/1.1 server with fiber-per-connection
- Radix-trie router with typed compile-time parameter extraction
- Plugin/hook system with Fastify-style encapsulation
- All 11 built-in plugins (Compress, CORS, Cookie, CSRF, FormBody, Multipart, OAuth2, SSE, Swagger, SwaggerUI, StaticFiles)
- OpenAPI 3.0.3 spec generation with Swagger UI
- Structured JSON logging

### Roadmap
- [x] CORS plugin
- [ ] WebSocket support
- [ ] HTTP/2
- [ ] Request body streaming
- [ ] Rate limiting plugin
- [ ] Session management plugin
- [ ] Unit test suite
- [ ] `haxelib.json` for package distribution
- [ ] Benchmarks and performance documentation
- [ ] CI/CD pipeline

## Contributing

Warp10 is part of the Fiberus ecosystem. Contributions welcome!
Check out the [Fiberus repo](https://github.com/fiberus-hx/fiberus) for the runtime and GC work that powers it.
