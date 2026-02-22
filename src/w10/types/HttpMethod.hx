package w10.types;

enum HttpMethod {
	Get;
	Post;
	Put;
	Delete;
	Patch;
	Head;
	Options;
}

class HttpMethodTools {
	public static function fromString(s:String):Null<HttpMethod> {
		return switch (s) {
			case "GET": Get;
			case "POST": Post;
			case "PUT": Put;
			case "DELETE": Delete;
			case "PATCH": Patch;
			case "HEAD": Head;
			case "OPTIONS": Options;
			default: null;
		};
	}

	public static function toString(m:HttpMethod):String {
		return switch (m) {
			case Get: "GET";
			case Post: "POST";
			case Put: "PUT";
			case Delete: "DELETE";
			case Patch: "PATCH";
			case Head: "HEAD";
			case Options: "OPTIONS";
		};
	}
}
