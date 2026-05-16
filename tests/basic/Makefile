
all: debug

release:
	@haxe compile.hxml --times

# Crash #7 bisect: release without jemalloc, to isolate whether the release-only
# SEGV is a jemalloc-interaction bug. Toolchain reads FIBERUS_NO_JEMALLOC and
# omits `-ljemalloc` from the link (linux-toolchain.xml:79,95).
release_nojemalloc:
	@haxe compile.hxml --times -D FIBERUS_NO_JEMALLOC=1

# Crash #7 forensics: -O3 release with -g symbols for rr / coredump replay.
release_rr:
	@haxe compile.hxml --times -D FIBERUS_DEBUG_SYMBOLS=1

debug:
	@haxe compile.hxml --times -debug -D FIBERUS_DEBUG -D FIBERUS_DEBUG_FIBERS

debug_tracy:
	@haxe compile.hxml --times -debug -D FIBERUS_TRACY -D TRACY_NO_EXIT

run:
	@bin/Main

clean:
	@rm -rf bin

cache_clear:
	@haxelib run fiberus cache clear

.PHONY: all release release_nojemalloc release_rr debug debug_tracy run clean cache_clear
