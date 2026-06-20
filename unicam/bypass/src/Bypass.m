// Bypass.m — in-process jailbreak / anti-debug bypass via dyld interposing.
// Loaded by ElleKit into the target app (no Frida), so it's active before the
// SDK's early checks run and is invisible to anti-frida logic.
//
// AUTHORIZED testing only: Unico HackerOne, your device, in-scope app.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <stdio.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <fcntl.h>
#import <unistd.h>

extern int ptrace(int, pid_t, caddr_t, int);

// dyld interpose macro.
#define DYLD_INTERPOSE(_repl, _orig) \
    __attribute__((used)) static struct { const void *repl; const void *orig; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_orig };

// ---- jailbreak path matcher ----
static const char *kJB[] = {
    "Cydia", "Sileo", "Zebra", "Filza", "MobileSubstrate", "substrate", "TweakInject",
    "/var/jb", "/bin/bash", "/bin/sh", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt",
    "/private/var/lib/cydia", "/private/var/stash", "cydia", "unc0ver", "undecimus",
    "checkra1n", "palera1n", "Dopamine", "libjailbreak", "frida", "cynject", "/jb",
    "/var/binpack", "/usr/libexec/cydia", "ellekit", "ElleKit", "/var/mobile/Library/Cydia"
};
static int looksJB(const char *p) {
    if (!p) return 0;
    for (size_t i = 0; i < sizeof(kJB) / sizeof(kJB[0]); i++)
        if (strstr(p, kJB[i])) return 1;
    return 0;
}

// ---- lazily-resolved originals (interposes are live before our ctor runs) ----
static int   (*real_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int   (*real_open)(const char *, int, ...);
static int   (*real_stat)(const char *, struct stat *);
static int   (*real_lstat)(const char *, struct stat *);
static int   (*real_access)(const char *, int);
static FILE *(*real_fopen)(const char *, const char *);
#define LAZY(p, name) do { if (!p) p = dlsym(RTLD_NEXT, name); } while (0)

// ---- anti-debug ----
static int my_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    return 0;                                  // swallow PT_DENY_ATTACH etc.
}
DYLD_INTERPOSE(my_ptrace, ptrace)

static int my_sysctl(int *name, u_int nlen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    LAZY(real_sysctl, "sysctl");
    int r = real_sysctl(name, nlen, oldp, oldlenp, newp, newlen);
    if (r == 0 && name && nlen >= 4 && name[0] == CTL_KERN && name[1] == KERN_PROC &&
        name[2] == KERN_PROC_PID && oldp) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        kp->kp_proc.p_flag &= ~P_TRACED;       // hide debugger flag
    }
    return r;
}
DYLD_INTERPOSE(my_sysctl, sysctl)

// ---- jailbreak file checks ----
static int my_open(const char *path, int flags, ...) {
    if (looksJB(path)) { errno = ENOENT; return -1; }
    LAZY(real_open, "open");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    return real_open(path, flags, mode);
}
DYLD_INTERPOSE(my_open, open)

static int my_stat(const char *path, struct stat *st) {
    if (looksJB(path)) { errno = ENOENT; return -1; }
    LAZY(real_stat, "stat"); return real_stat(path, st);
}
DYLD_INTERPOSE(my_stat, stat)

static int my_lstat(const char *path, struct stat *st) {
    if (looksJB(path)) { errno = ENOENT; return -1; }
    LAZY(real_lstat, "lstat"); return real_lstat(path, st);
}
DYLD_INTERPOSE(my_lstat, lstat)

static int my_access(const char *path, int mode) {
    if (looksJB(path)) { errno = ENOENT; return -1; }
    LAZY(real_access, "access"); return real_access(path, mode);
}
DYLD_INTERPOSE(my_access, access)

static FILE *my_fopen(const char *path, const char *m) {
    if (looksJB(path)) { errno = ENOENT; return NULL; }
    LAZY(real_fopen, "fopen"); return real_fopen(path, m);
}
DYLD_INTERPOSE(my_fopen, fopen)

// ---- Objective-C layer (swizzled in constructor) ----
static BOOL (*orig_fileExists)(id, SEL, id);
static BOOL my_fileExists(id self, SEL _cmd, id path) {
    @try { if (path && looksJB([[path description] UTF8String])) return NO; } @catch (__unused id e) {}
    return orig_fileExists(self, _cmd, path);
}
static BOOL (*orig_canOpenURL)(id, SEL, id);
static BOOL my_canOpenURL(id self, SEL _cmd, id url) {
    @try {
        NSString *s = [url absoluteString];
        if (s && looksJB([s UTF8String])) return NO;
    } @catch (__unused id e) {}
    return orig_canOpenURL(self, _cmd, url);
}

__attribute__((constructor))
static void BypassInit(void) {
    Class FM = objc_getClass("NSFileManager");
    Method m1 = class_getInstanceMethod(FM, @selector(fileExistsAtPath:));
    if (m1) { orig_fileExists = (void *)method_getImplementation(m1);
              method_setImplementation(m1, (IMP)my_fileExists); }

    Class UA = objc_getClass("UIApplication");
    Method m2 = class_getInstanceMethod(UA, @selector(canOpenURL:));
    if (m2) { orig_canOpenURL = (void *)method_getImplementation(m2);
              method_setImplementation(m2, (IMP)my_canOpenURL); }

    NSLog(@"[UnicoBypass] anti-debug + jailbreak hooks active");
}
