package w10.utils;

import haxe.io.Bytes;
import fiberus.io.FD;
import fiberus.io.OpenFlags;

/**
 * Cryptographic utilities for Warp10 plugins.
 *
 * Uses /dev/urandom for cryptographically secure random bytes
 * and provides constant-time comparison for token validation.
 */
class Crypto {
	/**
	 * Generate cryptographically secure random bytes.
	 *
	 * Reads from /dev/urandom which is non-blocking and suitable
	 * for cryptographic use on Linux. Returns null if the read fails.
	 */
	public static function randomBytes(n:Int):Null<Bytes> {
		var fd = FD.open("/dev/urandom", OpenFlags.O_RDONLY);
		if (fd < 0) return null;

		var buf = Bytes.alloc(n);
		var totalRead = 0;
		while (totalRead < n) {
			var read = FD.read(fd, buf, totalRead, n - totalRead);
			if (read <= 0) {
				FD.close(fd);
				return null;
			}
			totalRead += read;
		}
		FD.close(fd);
		return buf;
	}

	/**
	 * Constant-time comparison of two byte arrays.
	 *
	 * Prevents timing side-channel attacks by always comparing all
	 * bytes regardless of where the first difference is found.
	 * Returns true only if both arrays have the same length and
	 * identical contents.
	 */
	public static function constantTimeEqual(a:Bytes, b:Bytes):Bool {
		if (a.length != b.length) return false;

		var result = 0;
		var i = 0;
		while (i < a.length) {
			result = result | (a.get(i) ^ b.get(i));
			i++;
		}
		return result == 0;
	}
}
