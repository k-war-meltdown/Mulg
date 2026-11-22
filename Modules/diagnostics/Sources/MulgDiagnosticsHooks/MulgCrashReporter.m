//
//  MulgCrashReporter.m
//  diagnostics module: a report file when the game crashes (PLAN.md §8.3), and the C parts
//  of the debugger (main-thread backtraces, process numbers, console capture).
//
//  The signal handler allocates nothing and calls no Objective-C or stdio: it formats numbers
//  itself and writes with write(2). Memory is read with vm_read_overwrite, so a broken frame
//  chain or a bad string pointer cannot fault a second time. When the report is written the
//  handlers that were there before are put back and the handler returns: the faulting
//  instruction runs again and the game's own crash reporter, or macOS's, sees the crash as if
//  Mulg were not there.
//

#import "MulgDiagnosticsHooks.h"

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

static const int kSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT, SIGSYS };
enum { kSignalCount = sizeof(kSignals) / sizeof(kSignals[0]), kMaxFrames = 64, kContextSize = 32768 };

static struct sigaction previousActions[kSignalCount];
static NSUncaughtExceptionHandler *previousExceptionHandler;
static _Atomic(int) installed;
/// 0 = no crash, 1 = a report is being written, 2 = written.
static _Atomic(int) crashState;
static char directory[1024];
/// Two buffers, so a crash during an update still reads a whole context.
static char contexts[2][kContextSize];
static _Atomic(int) currentContext;
static char exceptionText[16384];
/// The debugger's log, or -1.
static _Atomic(int) debugLog = -1;
/// The thread mulg_debug_backtrace reads (the main thread).
static thread_act_t watchedThread = MACH_PORT_NULL;

// MARK: Writing without allocating

static void put(int fd, const char *text) {
    if (text) {
        write(fd, text, strlen(text));
    }
}

static void putHex(int fd, uint64_t value) {
    char digits[16];
    int count = 0;
    do {
        digits[count++] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    } while (value);
    char text[18] = { '0', 'x' };
    for (int i = 0; i < count; i++) {
        text[2 + i] = digits[count - 1 - i];
    }
    write(fd, text, 2 + count);
}

static void putDecimal(int fd, uint64_t value) {
    char text[20];
    int start = sizeof text;
    do {
        text[--start] = (char)('0' + value % 10);
        value /= 10;
    } while (value);
    write(fd, text + start, sizeof text - start);
}

static const char *signalName(int signal) {
    switch (signal) {
    case SIGSEGV: return "SIGSEGV";
    case SIGBUS: return "SIGBUS";
    case SIGILL: return "SIGILL";
    case SIGFPE: return "SIGFPE";
    case SIGTRAP: return "SIGTRAP (Swift runtime error or trap)";
    case SIGABRT: return "SIGABRT (abort)";
    case SIGSYS: return "SIGSYS";
    default: return "signal";
    }
}

static const char *fileName(const char *path) {
    const char *slash = path ? strrchr(path, '/') : NULL;
    return slash ? slash + 1 : (path ? path : "?");
}

// MARK: Reading memory that may be gone

static int readMemory(uint64_t address, void *out, size_t size) {
    vm_size_t copied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, size, (vm_address_t)out, &copied) == KERN_SUCCESS
        && copied == size;
}

/// Copies a C string one page at a time, so a string near unmapped memory is still read.
static int readString(uint64_t address, char *out, size_t size) {
    size_t length = 0;
    while (length + 1 < size) {
        size_t chunk = vm_page_size - (size_t)((address + length) % vm_page_size);
        if (chunk > size - 1 - length) {
            chunk = size - 1 - length;
        }
        if (!readMemory(address + length, out + length, chunk)) {
            break;
        }
        if (memchr(out + length, 0, chunk)) {
            return out[0] != 0;
        }
        length += chunk;
    }
    out[length] = 0;
    return length > 0;
}

/// Return addresses may carry pointer-authentication bits above the 47-bit user address space.
static uint64_t stripped(uint64_t address) {
    return address & 0x00007fffffffffffULL;
}

// MARK: Loaded images

enum { kMaxImages = 4096 };
typedef struct {
    char path[1024];
    uint64_t start, size;
    uint8_t uuid[16];
    bool hasUUID;
    uint64_t annotations[2];
} Image;
typedef struct {
    Image image; // Immutable after publication, including after its image unloads.
    _Atomic(bool) live;
} ImageSlot;
static ImageSlot images[kMaxImages];
static _Atomic(uint32_t) imageCount;

static void addedImage(const struct mach_header *raw, intptr_t slide) {
    (void)slide;
    const struct mach_header_64 *header = (const struct mach_header_64 *)raw;
    if (header->magic != MH_MAGIC_64) return;
    uint32_t index = atomic_fetch_add(&imageCount, 1);
    if (index >= kMaxImages) return; // Bounded, fail-soft metadata; never recycle storage a crash may read.
    Image *image = &images[index].image;
    image->start = (uint64_t)header;
    Dl_info info = {0};
    if (dladdr(header, &info) && info.dli_fname) strlcpy(image->path, info.dli_fname, sizeof image->path);
    const uint8_t *command = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmdsize < sizeof(*load)) break;
        if (load->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)load)->segname, SEG_TEXT) == 0) {
            image->size = ((const struct segment_command_64 *)load)->vmsize;
        } else if (load->cmd == LC_UUID) {
            memcpy(image->uuid, ((const struct uuid_command *)load)->uuid, sizeof image->uuid);
            image->hasUUID = true;
        }
        command += load->cmdsize;
    }
    const char *segments[] = { "__DATA", "__DATA_DIRTY" };
    for (int s = 0; s < 2; s++) {
        unsigned long size = 0;
        const void *section = getsectiondata(header, segments[s], "__crash_info", &size);
        if (section && size >= 5 * sizeof(uint64_t)) image->annotations[s] = (uint64_t)section;
    }
    atomic_store_explicit(&images[index].live, true, memory_order_release);
}

static void removedImage(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    uint32_t count = MIN(atomic_load(&imageCount), kMaxImages);
    for (uint32_t i = 0; i < count; i++) {
        if (atomic_load(&images[i].live) && images[i].image.start == (uint64_t)header) atomic_store(&images[i].live, false);
    }
}

static void watchImages(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Callbacks run during normal loader work, never in the signal handler.
        _dyld_register_func_for_add_image(addedImage);
        _dyld_register_func_for_remove_image(removedImage);
    });
}

static int imageAt(uint32_t index, Image *image) {
    if (index >= MIN(atomic_load(&imageCount), kMaxImages)
        || !atomic_load_explicit(&images[index].live, memory_order_acquire)) return 0;
    *image = images[index].image;
    return 1;
}

static int64_t imageContaining(uint64_t address, Image *image) {
    uint32_t count = MIN(atomic_load(&imageCount), kMaxImages);
    for (uint32_t i = 0; i < count; i++) {
        if (imageAt(i, image) && address >= image->start && address - image->start < image->size) return i;
    }
    return -1;
}

/// Annotation addresses are captured while their image is mapped; crash-time reads tolerate unloads.
static void putCrashMessages(int fd) {
    struct Annotations { uint64_t version, message, signature, backtrace, message2; };
    uint32_t count = MIN(atomic_load(&imageCount), kMaxImages);
    for (uint32_t i = 0; i < count; i++) {
        Image image;
        if (!imageAt(i, &image)) continue;
        for (int s = 0; s < 2; s++) {
            struct Annotations annotation;
            if (!image.annotations[s] || !readMemory(image.annotations[s], &annotation, sizeof annotation)) continue;
            uint64_t messages[2] = { annotation.message, annotation.message2 };
            for (int m = 0; m < 2; m++) {
                char text[2048];
                if (messages[m] && readString(messages[m], text, sizeof text)) {
                    put(fd, fileName(image.path)); put(fd, ": "); put(fd, text); put(fd, "\n");
                }
            }
        }
    }
}

// MARK: The report

static void putThread(int fd) {
    char name[64] = "";
    pthread_getname_np(pthread_self(), name, sizeof name);
    uint64_t thread = 0;
    pthread_threadid_np(NULL, &thread);
    put(fd, "Thread: ");
    putDecimal(fd, thread);
    put(fd, pthread_main_np() ? " (main)" : "");
    if (name[0]) {
        put(fd, " \"");
        put(fd, name);
        put(fd, "\"");
    }
    put(fd, "\n");
}

/// The frame-pointer chain. A leaf function saves no frame, so its caller is only in lr.
static int walkFrames(uint64_t pc, uint64_t fp, uint64_t frames[kMaxFrames]) {
    int frameCount = 0;
    frames[frameCount++] = pc;
    while (fp && frameCount < kMaxFrames) {
        uint64_t pair[2];
        if (!readMemory(fp, pair, sizeof pair) || !pair[1]) {
            break;
        }
        frames[frameCount++] = stripped(pair[1]);
        if (pair[0] <= fp) {
            break;  // callers sit higher on the stack
        }
        fp = pair[0];
    }
    return frameCount;
}

/// "3  0x104a3f10c  MulgRuntime + 0x1310c" per frame, then what atos needs for each image.
static void putBacktrace(int fd, const uint64_t *frames, int frameCount) {
    int64_t used[kMaxFrames];
    int usedCount = 0;
    for (int i = 0; i < frameCount; i++) {
        Image image;
        int64_t index = imageContaining(frames[i], &image);
        putDecimal(fd, (uint64_t)i);
        put(fd, "  ");
        putHex(fd, frames[i]);
        if (index >= 0) {
            put(fd, "  ");
            put(fd, fileName(image.path));
            put(fd, " + ");
            putHex(fd, frames[i] - image.start);
            int seen = 0;
            for (int u = 0; u < usedCount; u++) {
                seen |= used[u] == index;
            }
            if (!seen) {
                used[usedCount++] = index;
            }
        }
        put(fd, "\n");
    }

    // What atos needs: atos -o <binary> -l <load address> <address>.
    put(fd, "\nImages in the backtrace (load address, UUID, path)\n");
    for (int u = 0; u < usedCount; u++) {
        Image image;
        if (!imageAt((uint32_t)used[u], &image)) {
            continue;
        }
        putHex(fd, image.start);
        put(fd, "  ");
        for (int b = 0; image.hasUUID && b < 16; b++) {
            char hex[2] = { "0123456789ABCDEF"[image.uuid[b] >> 4], "0123456789ABCDEF"[image.uuid[b] & 0xf] };
            write(fd, hex, 2);
        }
        put(fd, "  ");
        put(fd, image.path);
        put(fd, "\n");
    }
}

static void writeReport(int signal, siginfo_t *info, ucontext_t *context) {
    char path[sizeof directory + 64]; // "/Crash-", two 20-digit numbers, "-" and ".txt" fit
    size_t length = strlcpy(path, directory, sizeof path);
    strlcpy(path + length, "/Crash-", sizeof path - length);
    length += 7;
    char digits[20];
    int start = sizeof digits;
    uint64_t now = (uint64_t)time(NULL);
    do {
        digits[--start] = (char)('0' + now % 10);
        now /= 10;
    } while (now);
    memcpy(path + length, digits + start, sizeof digits - start);
    length += sizeof digits - start;
    // "-<pid>": two crashes in the same second (the game relaunched at once) no longer write one file.
    path[length++] = '-';
    uint64_t pid = (uint64_t)getpid();
    start = sizeof digits;
    do {
        digits[--start] = (char)('0' + pid % 10);
        pid /= 10;
    } while (pid);
    memcpy(path + length, digits + start, sizeof digits - start);
    length += sizeof digits - start;
    strlcpy(path + length, ".txt", sizeof path - length);

    int logFd = atomic_load(&debugLog);
    if (logFd >= 0) {
        put(logFd, "\n*** The game crashed: ");
        put(logFd, signalName(signal));
        put(logFd, ". Report: ");
        put(logFd, fileName(path));
        put(logFd, "\n");
    }

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return;
    }
    put(fd, "Mulg crash report\n\nSignal: ");
    put(fd, signalName(signal));
    put(fd, " (");
    putDecimal(fd, (uint64_t)signal);
    put(fd, "), code ");
    putDecimal(fd, (uint64_t)info->si_code);
    put(fd, ", address ");
    putHex(fd, (uint64_t)info->si_addr);
    put(fd, "\nTime: ");
    putDecimal(fd, (uint64_t)time(NULL));
    put(fd, " (Unix)\n");
    putThread(fd);

    put(fd, "\nMessages\n");
    putCrashMessages(fd);
    if (exceptionText[0]) {
        put(fd, "\nUncaught exception\n");
        put(fd, exceptionText);
        put(fd, "\n");
    }

    uint64_t frames[kMaxFrames];
    int frameCount = 0;
#if defined(__arm64__)
    if (context && context->uc_mcontext) {
        const _STRUCT_ARM_THREAD_STATE64 *state = &context->uc_mcontext->__ss;
        put(fd, "\nRegisters\n");
        for (int i = 0; i < 29; i++) {
            put(fd, "x");
            putDecimal(fd, (uint64_t)i);
            put(fd, " ");
            putHex(fd, state->__x[i]);
            put(fd, i % 4 == 3 ? "\n" : "  ");
        }
        put(fd, "\nfp ");
        putHex(fd, (uint64_t)arm_thread_state64_get_fp(*state));
        put(fd, "  lr ");
        putHex(fd, stripped((uint64_t)arm_thread_state64_get_lr(*state)));
        put(fd, "  sp ");
        putHex(fd, (uint64_t)arm_thread_state64_get_sp(*state));
        put(fd, "  pc ");
        putHex(fd, stripped((uint64_t)arm_thread_state64_get_pc(*state)));
        put(fd, "\n");

        // A crash inside objc_msgSend: x1 is the selector sent to a freed or wrong object.
        Image image;
        uint64_t pc = stripped((uint64_t)arm_thread_state64_get_pc(*state));
        char selector[256];
        if (imageContaining(pc, &image) >= 0 && strstr(fileName(image.path), "libobjc")
            && readString(state->__x[1], selector, sizeof selector)) {
            put(fd, "Selector (x1): ");
            put(fd, selector);
            put(fd, "\n");
        }

        frameCount = walkFrames(pc, (uint64_t)arm_thread_state64_get_fp(*state), frames);
    }
#endif

    put(fd, "\nBacktrace of the crashed thread\n");
    putBacktrace(fd, frames, frameCount);

    put(fd, "\n");
    put(fd, contexts[atomic_load(&currentContext)]);
    put(fd, "\n");
    close(fd);
}

static void handleSignal(int signal, siginfo_t *info, void *context) {
    int idle = 0;
    if (!atomic_load(&installed)) {
        // Uninstalled, but still chained behind a handler the game added: only pass it on.
    } else if (atomic_compare_exchange_strong(&crashState, &idle, 1)) {
        writeReport(signal, info, (ucontext_t *)context);
        atomic_store(&crashState, 2);
    } else {
        // Another thread is writing the report: let it finish before this one ends the game.
        // nanosleep, not usleep: it is async-signal-safe.
        for (int i = 0; i < 100 && atomic_load(&crashState) == 1; i++) {
            nanosleep(&(struct timespec){ .tv_nsec = 20000000 }, NULL);
        }
    }
    for (int i = 0; i < kSignalCount; i++) {
        sigaction(kSignals[i], &previousActions[i], NULL);
    }
    // A fault happens again when the instruction reruns; abort() and a bad system call do not,
    // so send those again. The signal is blocked here and arrives at the old handler on return.
    if (signal == SIGABRT || signal == SIGSYS) {
        raise(signal);
    }
}

static void handleException(NSException *exception) {
    // The first uncaught exception ends the game; one thrown on another thread meanwhile must
    // not write over its text.
    static _Atomic(int) claimed;
    if (atomic_load(&installed) && !atomic_exchange(&claimed, 1)) {
        NSString *text = [NSString stringWithFormat:@"%@: %@\n%@", exception.name, exception.reason,
                                                    [exception.callStackSymbols componentsJoinedByString:@"\n"]];
        strlcpy(exceptionText, text.UTF8String ?: "", sizeof exceptionText);
    }
    if (previousExceptionHandler) {
        previousExceptionHandler(exception);
    }
}

void mulg_crash_install(const char *path) {
    if (atomic_exchange(&installed, 1)) {
        return;
    }
    strlcpy(directory, path, sizeof directory);
    watchImages();

    // Room to run on when the crash is the main thread running out of stack. Other threads
    // have none, so their stack overflows end without a report.
    stack_t current;
    if (sigaltstack(NULL, &current) == 0 && (current.ss_flags & SS_DISABLE)) {
        stack_t stack = { .ss_sp = malloc(SIGSTKSZ), .ss_size = SIGSTKSZ };
        if (stack.ss_sp) {
            sigaltstack(&stack, NULL);
        }
    }

    struct sigaction action = { .sa_sigaction = handleSignal, .sa_flags = SA_SIGINFO | SA_ONSTACK };
    sigemptyset(&action.sa_mask);
    for (int i = 0; i < kSignalCount; i++) {
        sigaddset(&action.sa_mask, kSignals[i]);
    }
    for (int i = 0; i < kSignalCount; i++) {
        sigaction(kSignals[i], &action, &previousActions[i]);
    }

    previousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&handleException);
}

// ponytail: the main thread's alternate signal stack stays (memory only, never used again).
void mulg_crash_uninstall(void) {
    if (!atomic_exchange(&installed, 0)) {
        return;
    }
    for (int i = 0; i < kSignalCount; i++) {
        struct sigaction current;
        if (sigaction(kSignals[i], NULL, &current) == 0 && current.sa_sigaction == handleSignal) {
            sigaction(kSignals[i], &previousActions[i], NULL);
        }
    }
    if (NSGetUncaughtExceptionHandler() == &handleException) {
        NSSetUncaughtExceptionHandler(previousExceptionHandler);
    }
}

void mulg_crash_write_context(int fd) {
    put(fd, contexts[atomic_load(&currentContext)]);
}

/// Main thread only (the diagnostics module is main-actor), so two updates never overlap.
void mulg_crash_set_context(const char *text) {
    int next = 1 - atomic_load(&currentContext);
    strlcpy(contexts[next], text, kContextSize);
    atomic_store(&currentContext, next);
}

// MARK: Debugger (settings `diagnostics.debugger`)

void mulg_debug_set_log(int fd) {
    atomic_store(&debugLog, fd);
}

void mulg_debug_watch_this_thread(void) {
    watchImages();
    if (watchedThread == MACH_PORT_NULL) {
        watchedThread = mach_thread_self();
    }
}

#if defined(__arm64__)
/// Only the frame chain is copied while the thread is stopped: it may hold the malloc or dyld
/// lock, so nothing that could take one runs until it is let go.
static int copyFrames(thread_act_t thread, uint64_t frames[kMaxFrames]) {
    if (thread == MACH_PORT_NULL || thread_suspend(thread) != KERN_SUCCESS) return 0;
    int frameCount = 0;
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
        frameCount = walkFrames(stripped((uint64_t)arm_thread_state64_get_pc(state)),
                                (uint64_t)arm_thread_state64_get_fp(state), frames);
    }
    thread_resume(thread);
    return frameCount;
}
#endif

void mulg_debug_backtrace(int fd) {
#if defined(__arm64__)
    uint64_t frames[kMaxFrames];
    int frameCount = copyFrames(watchedThread, frames);
    if (frameCount > 0) putBacktrace(fd, frames, frameCount);
#endif
}

// MARK: Hang reports

static thread_act_t hangMainThread = MACH_PORT_NULL;

void mulg_hang_watch_main_thread(void) {
    watchImages();
    if (hangMainThread == MACH_PORT_NULL) hangMainThread = mach_thread_self();
}

/// ": running, CPU 99%": a spinning thread and one waiting for it look very different here.
static void putThreadState(int fd, thread_act_t thread) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) {
        put(fd, "\n");
        return;
    }
    put(fd, info.run_state == TH_STATE_RUNNING ? ": running" : info.run_state == TH_STATE_WAITING ? ": waiting"
        : info.run_state == TH_STATE_UNINTERRUPTIBLE ? ": uninterruptible" : ": stopped");
    put(fd, ", CPU ");
    putDecimal(fd, (uint64_t)info.cpu_usage * 100 / TH_USAGE_SCALE);
    put(fd, "%\n");
}

void mulg_hang_snapshot(int fd) {
#if defined(__arm64__)
    uint64_t frames[kMaxFrames];
    if (hangMainThread != MACH_PORT_NULL) {
        put(fd, "Main thread");
        putThreadState(fd, hangMainThread);
        put(fd, "Backtrace of the hung main thread\n");
        putBacktrace(fd, frames, copyFrames(hangMainThread, frames));
    }
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;
    thread_act_t me = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_act_t thread = threads[i];
        if (thread != me && thread != hangMainThread) {
            char name[64] = "";
            pthread_t handle = pthread_from_mach_thread_np(thread);
            if (handle) pthread_getname_np(handle, name, sizeof name);
            put(fd, "\nThread ");
            putDecimal(fd, i);
            if (name[0]) {
                put(fd, " \"");
                put(fd, name);
                put(fd, "\"");
            }
            putThreadState(fd, thread);
            putBacktrace(fd, frames, copyFrames(thread, frames));
        }
        mach_port_deallocate(mach_task_self(), thread);
    }
    mach_port_deallocate(mach_task_self(), me);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
#endif
}

/// Where stdout and stderr went before mulg_debug_redirect_console; -1 while not redirected.
static int savedStdout = -1, savedStderr = -1;

// The runtime starts inside a load-time constructor. A game thread (or the main thread, still
// in that constructor) writing to a full pipe whose reader is waiting for anything that thread
// holds would never return; with a non-blocking write end the line is dropped instead.
int mulg_debug_console_pipe(int ends[2]) {
    if (pipe(ends) != 0) {
        return -1;
    }
    int flags = fcntl(ends[1], F_GETFL);
    if (flags < 0 || fcntl(ends[1], F_SETFL, flags | O_NONBLOCK) != 0
        || fcntl(ends[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(ends[1], F_SETFD, FD_CLOEXEC) != 0) {
        int saved = errno;
        close(ends[0]);
        close(ends[1]);
        errno = saved;
        return -1;
    }
    return 0;
}

void mulg_debug_redirect_console(int fd) {
    if (savedStdout >= 0) {
        return;
    }
    fflush(stdout);
    fflush(stderr);
    savedStdout = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0);
    savedStderr = fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 0);
    setvbuf(stdout, NULL, _IOLBF, 0);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
}

void mulg_debug_restore_console(void) {
    if (savedStdout < 0) {
        return;
    }
    fflush(stdout);
    fflush(stderr);
    dup2(savedStdout, STDOUT_FILENO);
    dup2(savedStderr, STDERR_FILENO);
    close(savedStdout);
    close(savedStderr);
    savedStdout = savedStderr = -1;
}

MulgProcessStats mulg_debug_process_stats(void) {
    MulgProcessStats stats = { 0 };
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        stats.cpuSeconds = (double)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
    }
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        stats.footprint = info.phys_footprint;
    }
    thread_act_array_t threads;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) == KERN_SUCCESS) {
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
        stats.threads = threadCount;
    }
    return stats;
}
