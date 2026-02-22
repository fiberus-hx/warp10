package w10.types;

class HttpStatus {
	// 2xx Success
	public static inline final OK = 200;
	public static inline final CREATED = 201;
	public static inline final NO_CONTENT = 204;

	// 3xx Redirection
	public static inline final MOVED_PERMANENTLY = 301;
	public static inline final FOUND = 302;
	public static inline final NOT_MODIFIED = 304;
	public static inline final TEMPORARY_REDIRECT = 307;
	public static inline final PERMANENT_REDIRECT = 308;

	// 4xx Client Error
	public static inline final BAD_REQUEST = 400;
	public static inline final UNAUTHORIZED = 401;
	public static inline final FORBIDDEN = 403;
	public static inline final NOT_FOUND = 404;
	public static inline final METHOD_NOT_ALLOWED = 405;
	public static inline final REQUEST_TIMEOUT = 408;
	public static inline final CONFLICT = 409;
	public static inline final PAYLOAD_TOO_LARGE = 413;
	public static inline final URI_TOO_LONG = 414;
	public static inline final UNPROCESSABLE_ENTITY = 422;
	public static inline final TOO_MANY_REQUESTS = 429;

	// 5xx Server Error
	public static inline final INTERNAL_SERVER_ERROR = 500;
	public static inline final NOT_IMPLEMENTED = 501;
	public static inline final BAD_GATEWAY = 502;
	public static inline final SERVICE_UNAVAILABLE = 503;
	public static inline final GATEWAY_TIMEOUT = 504;

	public static function reason(code:Int):String {
		return switch (code) {
			case 200: "OK";
			case 201: "Created";
			case 204: "No Content";
			case 301: "Moved Permanently";
			case 302: "Found";
			case 304: "Not Modified";
			case 307: "Temporary Redirect";
			case 308: "Permanent Redirect";
			case 400: "Bad Request";
			case 401: "Unauthorized";
			case 403: "Forbidden";
			case 404: "Not Found";
			case 405: "Method Not Allowed";
			case 408: "Request Timeout";
			case 409: "Conflict";
			case 413: "Payload Too Large";
			case 414: "URI Too Long";
			case 422: "Unprocessable Entity";
			case 429: "Too Many Requests";
			case 500: "Internal Server Error";
			case 501: "Not Implemented";
			case 502: "Bad Gateway";
			case 503: "Service Unavailable";
			case 504: "Gateway Timeout";
			default: "Unknown";
		};
	}
}
