//
//  MulgDiagnosticsHooks.h
//  diagnostics module: crash reports (PLAN.md §8.3) and the debugger's C helpers.
//

#ifndef MULG_DIAGNOSTICS_HOOKS_H
#define MULG_DIAGNOSTICS_HOOKS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs the crash signal handlers and the uncaught-exception handler, chained to the ones
/// already there. On a crash, `Crash-<unix time>-<pid>.txt` is written to `directory`, which must
/// exist. Nothing is written while the game runs normally. Only the first call does anything.
void mulg_crash_install(const char *_Nonnull directory);

/// Undoes mulg_crash_install: puts the handlers from before back where they are still Mulg's.
/// Where the game has since chained its own in front, Mulg's only pass the crash on.
void mulg_crash_uninstall(void);

/// The text added to the end of every report: versions, settings, module states. Copied, so
/// the caller keeps ownership. Call from one thread only (the main thread).
void mulg_crash_set_context(const char *_Nonnull text);
/// Writes the current context text to `fd` without allocating (freeze reports). Any thread.
void mulg_crash_write_context(int fd);

// MARK: Debugger (settings `diagnostics.debugger`)

/// The debugger's log. A crash also writes one line there naming its report. -1 for none.
void mulg_debug_set_log(int fd);

/// Remembers the calling thread as the one `mulg_debug_backtrace` reads. Call on the main thread.
void mulg_debug_watch_this_thread(void);

/// Stops the remembered thread for a moment, copies its frame chain, lets it run again, then
/// writes the backtrace and the images it runs in to `fd`, in the crash report's format.
void mulg_debug_backtrace(int fd);

/// Remembers the calling thread as the main thread for hang reports. Call on the main thread.
void mulg_hang_watch_main_thread(void);

/// Writes the main thread's backtrace ("Backtrace of the hung main thread", the crash report's
/// format), then every other thread's with its run state and CPU use. Each thread is stopped
/// only while its frame chain is copied. Never call it on the main thread.
void mulg_hang_snapshot(int fd);

/// A pipe for the console: `ends[0]` is read by the debugger, `ends[1]` is given to
/// `mulg_debug_redirect_console`. Both close on exec; the write end never blocks, so a game
/// printing faster than the debugger reads loses lines instead of freezing. 0, or -1 and errno.
int mulg_debug_console_pipe(int ends[_Nonnull 2]);

/// Sends stdout and stderr to `fd`, stdout line-buffered so each line arrives when printed.
void mulg_debug_redirect_console(int fd);

/// Sends stdout and stderr back where they went before the redirect. Nothing without one.
void mulg_debug_restore_console(void);

typedef struct {
    /// User and system time of all threads so far.
    double cpuSeconds;
    /// The memory footprint macOS charges the game with (Activity Monitor's "Memory").
    uint64_t footprint;
    uint32_t threads;
} MulgProcessStats;

MulgProcessStats mulg_debug_process_stats(void);

#ifdef __cplusplus
}
#endif

#endif
