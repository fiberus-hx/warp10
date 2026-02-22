
all: debug

release:
	@haxe compile.hxml --times

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

.PHONY: all release debug debug_tracy run clean cache_clear
