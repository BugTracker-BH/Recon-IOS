// antidetect.js — defeat common iOS jailbreak + anti-debug checks so an
// instrumented app will launch. Load BEFORE recon.js, at spawn.
// Authorized testing only (Unico HackerOne, your device, in-scope app).
//
//   frida -H <ip>:47000 -f <bundle.id> -l antidetect.js -l recon.js

(function () {
    function ex(n) { return Module.findExportByName(null, n); }

    // 1) Anti-debug: ptrace(PT_DENY_ATTACH) -> no-op.
    try {
        const p = ex('ptrace');
        if (p) Interceptor.replace(p, new NativeCallback(function () { return 0; },
            'int', ['int', 'int', 'pointer', 'int']));
    } catch (e) {}

    // 2) Anti-debug: sysctl() KERN_PROC -> clear P_TRACED flag in kinfo_proc.
    try {
        const sysctl = ex('sysctl');
        const P_TRACED = 0x00000800;
        if (sysctl) Interceptor.attach(sysctl, {
            onEnter(a) { this.oldp = a[2]; },
            onLeave() {
                try {
                    if (this.oldp.isNull()) return;
                    const flags = this.oldp.add(32).readU32();   // p_flag offset in kinfo_proc
                    if (flags & P_TRACED) this.oldp.add(32).writeU32(flags & ~P_TRACED);
                } catch (e) {}
            }
        });
    } catch (e) {}

    // 3) getppid spoof (debugger sets non-launchd parent).
    try {
        const g = ex('getppid');
        if (g) Interceptor.replace(g, new NativeCallback(function () { return 1; }, 'int', []));
    } catch (e) {}

    // 4) Jailbreak file-existence checks via libc.
    const jb = ['Cydia', 'Sileo', 'Zebra', 'Filza', 'MobileSubstrate', 'substrate',
        'TweakInject', 'apt', 'dpkg', '/var/jb', '/bin/bash', '/bin/sh', '/usr/sbin/sshd',
        '/etc/apt', 'cydia', 'undecimus', 'unc0ver', 'frida', 'cynject', '/jb',
        'libjailbreak', '/private/var/stash', '/var/binpack', 'checkra1n', 'palera1n', 'Dopamine'];
    function looksJB(s) { if (!s) return false; for (let i = 0; i < jb.length; i++) if (s.indexOf(jb[i]) !== -1) return true; return false; }

    ['open', 'open$NOCANCEL', 'stat', 'stat64', 'lstat', 'lstat64', 'access', 'faccessat'].forEach(function (fn) {
        const f = ex(fn); if (!f) return;
        Interceptor.attach(f, {
            onEnter(a) { try { this.jb = looksJB(a[0].readUtf8String()); } catch (e) { this.jb = false; } },
            onLeave(r) { if (this.jb) r.replace(ptr(-1)); }
        });
    });
    ['fopen', 'fopen$NOCANCEL'].forEach(function (fn) {
        const f = ex(fn); if (!f) return;
        Interceptor.attach(f, {
            onEnter(a) { try { this.jb = looksJB(a[0].readUtf8String()); } catch (e) { this.jb = false; } },
            onLeave(r) { if (this.jb) r.replace(ptr(0)); }   // NULL
        });
    });

    // 5) fork() probe -> fail (sandboxed apps can't fork; JB detectors test this).
    try { const f = ex('fork'); if (f) Interceptor.replace(f, new NativeCallback(function () { return -1; }, 'int', [])); } catch (e) {}

    // 6) Objective-C layer.
    if (ObjC.available) {
        try {
            const FM = ObjC.classes.NSFileManager;
            ['- fileExistsAtPath:', '- fileExistsAtPath:isDirectory:'].forEach(function (sel) {
                const m = FM[sel]; if (!m) return;
                Interceptor.attach(m.implementation, {
                    onEnter(a) { try { this.jb = looksJB(new ObjC.Object(a[2]).toString()); } catch (e) { this.jb = false; } },
                    onLeave(r) { if (this.jb) r.replace(ptr(0)); }   // NO
                });
            });
        } catch (e) {}
        try {
            const m = ObjC.classes.UIApplication['- canOpenURL:'];
            Interceptor.attach(m.implementation, {
                onEnter(a) { try { this.jb = looksJB(new ObjC.Object(a[2]).absoluteString().toString()); } catch (e) { this.jb = false; } },
                onLeave(r) { if (this.jb) r.replace(ptr(0)); }
            });
        } catch (e) {}
    }

    console.log('[antidetect] jailbreak/anti-debug hooks installed');
})();
