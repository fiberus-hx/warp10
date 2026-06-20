
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

# Crash #7 bracket test: -O1 release (vs default -O3) to isolate codegen
# hoisting from runtime GC bugs. ASAN (-O1) is clean; this run controls for
# optimization level WITHOUT the sanitizer's other interpositions.
release_o1:
	@haxe compile.hxml --times -D FIBERUS_O1=1

# -O0 release for full optimization-level bisection. Lets us distinguish
# compiler-driven UB (would only manifest at -O3) from real runtime bugs.
release_o0:
	@haxe compile.hxml --times -D FIBERUS_O0=1 -D FIBERUS_DEBUG_SYMBOLS=1

# Phase D of -O bisect: -O3 + -fno-strict-aliasing. The -O0/-O3 split
# (7/10 vs 2/10 PASS) confirmed compiler UB; this isolates strict-aliasing
# (most common -O3 UB) as the specific cause. If PASS rate jumps to ~-O0
# levels, the bug is type-punning + strict-aliasing.
release_nosa:
	@haxe compile.hxml --times -D FIBERUS_NO_STRICT_ALIASING=1 -D FIBERUS_DEBUG_SYMBOLS=1

# -O2 narrowing build for -O bisect Phase D-2. Tests whether the UB is
# isolated to -O3-only passes (vectorize / predictive-commoning) or lives
# in the -O1/-O2 transformation set.
release_o2:
	@haxe compile.hxml --times -D FIBERUS_O2=1 -D FIBERUS_DEBUG_SYMBOLS=1

# Phase D-3: -O1 + (IPA-modref/pure-const/icf/cp/reference disabled +
# tree-pre/partial-pre/dse/fre/sink disabled + gcse/gcse-lm disabled).
# Tests load-hoisting / store-eliminating / IPA-purity bug class.
release_o1_safe:
	@haxe compile.hxml --times -D FIBERUS_O1=1 -D FIBERUS_O1_SAFE=1 -D FIBERUS_DEBUG_SYMBOLS=1

# Phase D-4: complementary -O1 disable set (tree-vrp/sra/dce/ccp family +
# tree-pta + inline-once + if-conv).
release_o1_safe_b:
	@haxe compile.hxml --times -D FIBERUS_O1=1 -D FIBERUS_O1_SAFE_B=1 -D FIBERUS_DEBUG_SYMBOLS=1

# AddressSanitizer build: catches heap buffer overflows, use-after-free, etc.
# Toolchain auto-sets FIBERUS_NO_JEMALLOC=1 when FIBERUS_ASAN (linux-toolchain.xml:16).
# Uses -O1 because -O3 + ASAN can hit false positives from aggressive inlining.
# Debug symbols are included so ASAN can produce useful backtraces.
release_asan:
	@haxe compile.hxml --times -D FIBERUS_ASAN=1 -D FIBERUS_O1=1 -D FIBERUS_DEBUG_SYMBOLS=1

# H6 UAF detector build: probes at fib_reflect_fields + fib_string_concat
# entry check for stale GC pointers (FORWARDED bit set OR header corrupted).
# Used to localize the UAF source by catching at point-of-use with caller chain.
release_uafchk:
	@haxe compile.hxml --times -D FIBERUS_UAF_CHECK=1 -D FIBERUS_DEBUG_SYMBOLS=1

# Finalizer-registry diagnostic: logs DUP detection in register + every
# fib_array_destruct call. Used to confirm double-finalize hypothesis for
# fib_array_mark crashes. Output goes to stderr (server.log via crash_test.sh).
release_finreg:
	@haxe compile.hxml --times -D FIBERUS_DEBUG_FINREG=1 -D FIBERUS_DEBUG_SYMBOLS=1

# Task #22 diagnostic: logs every is_gc_pointer-accepted-but-is_object_start-rejected
# obj address in mark_object_internal. Used to identify the bit-position mismatch
# between writer (allocator) and reader (is_object_start_in_block).
release_objstart:
	@haxe compile.hxml --times -D FIBERUS_DEBUG_OBJSTART=1 -D FIBERUS_DEBUG_SYMBOLS=1

# Phase 1 diagnostic (post task #54): fires [ALLOC_LIVE] when fibrix_alloc_zeroed
# is about to memset a slot the GC still believes is live. Classifies residual
# Logger.child:370 + "warp10" RIP crashes between H-A (alloc-vs-mark race) and
# H-B (cross-thread root coverage). See /home/mib/.claude/plans/serialized-strolling-truffle.md
release_alloclive:
	@haxe compile.hxml --times -D FIBERUS_DEBUG_ALLOC_LIVE=1 -D FIBERUS_DEBUG_SYMBOLS=1

# ThreadSanitizer build: catches data races between threads.
# Toolchain auto-sets FIBERUS_NO_JEMALLOC=1 when FIBERUS_TSAN (linux-toolchain.xml:17).
# Uses -O1 because -O3 + TSan can produce noisier reports from inlining.
release_tsan:
	@haxe compile.hxml --times -D FIBERUS_TSAN=1 -D FIBERUS_O1=1 -D FIBERUS_DEBUG_SYMBOLS=1

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

.PHONY: all release release_nojemalloc release_rr release_o1 release_o0 release_o2 release_o1_safe release_o1_safe_b release_nosa release_asan release_uafchk release_finreg release_objstart release_tsan debug debug_tracy run clean cache_clear
