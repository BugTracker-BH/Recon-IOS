// recon.js — Map the Unico liveness SDK: camera capture, Flutter bridge,
// backend submission, and JWT. Authorized use: Unico IDTech HackerOne bounty,
// in-scope TestFlight test apps, on a device you own.
//
// Usage (spawn):  frida -U -f <bundle.id> -l recon.js --no-pause
//        (attach): frida -U -n <AppName> -l recon.js
// vs frida detection: run frida-server on a custom port and use frida -H.

if (!ObjC.available) { console.log('[recon] ObjC runtime NOT available'); }
else {
    console.log('[recon] ObjC available');
    try {
        console.log('[recon] bundle id: ' +
            ObjC.classes.NSBundle.mainBundle().bundleIdentifier());
    } catch (e) {}

    function hook(cls, sel, onEnter) {
        try {
            Interceptor.attach(ObjC.classes[cls][sel].implementation, { onEnter: onEnter });
            console.log('[hooked] -[' + cls + ' ' + sel + ']');
        } catch (e) { /* not present in this build */ }
    }

    // 1) SDK-relevant classes.
    const needles = ['unico', 'liveness', 'capture', 'camera', 'face',
                     'biometr', 'selfie', 'sensor', 'detect', 'jwt', 'process'];
    Object.keys(ObjC.classes).forEach(function (n) {
        const low = n.toLowerCase();
        if (needles.some(function (k) { return low.indexOf(k) !== -1; }))
            console.log('[class] ' + n);
    });

    // 2) Camera pipeline (the UniCam tweak's target).
    hook('AVCaptureSession', '- startRunning', function () {
        console.log('[cap] AVCaptureSession startRunning');
    });
    hook('AVCaptureVideoDataOutput', '- setSampleBufferDelegate:queue:', function (args) {
        try {
            const d = new ObjC.Object(args[2]);
            const sel = 'captureOutput:didOutputSampleBuffer:fromConnection:';
            console.log('[cap] video frame delegate = ' + d.$className + '  <-- injection point');
            let once = false;
            Interceptor.attach(ObjC.classes[d.$className][sel].implementation,
                { onEnter: function () { if (!once) { once = true;
                    console.log('[frame] ' + d.$className + ' receiving sample buffers'); } } });
        } catch (e) { console.log('[warn] frame-cb hook: ' + e); }
    });
    hook('AVCapturePhotoOutput', '- capturePhotoWithSettings:delegate:', function (args) {
        try { console.log('[cap] AVCapturePhotoOutput delegate = ' +
                          new ObjC.Object(args[3]).$className +
                          '  (still-capture path — tweak needs a 2nd hook here)'); } catch (e) {}
    });

    // 3) Flutter bridge — what crosses Dart <-> native (config + image channels).
    function channelName(ch) {
        try { return ch.$ivars['_name'].toString(); } catch (e) {}
        try { return ch.name().toString(); } catch (e) {}
        return '?';
    }
    ['- invokeMethod:arguments:', '- invokeMethod:arguments:result:'].forEach(function (sel) {
        hook('FlutterMethodChannel', sel, function (args) {
            try {
                const ch = new ObjC.Object(args[0]);
                const method = new ObjC.Object(args[2]).toString();
                const a = args[3] ? new ObjC.Object(args[3]) : null;
                let info = a ? (a.$className) : 'nil';
                // Surface payload size if it's NSData (likely the image bytes).
                try { if (a && a.isKindOfClass_(ObjC.classes.NSData)) info = 'NSData len=' + a.length(); } catch (e) {}
                console.log('[bridge] ' + channelName(ch) + ' -> ' + method + '  arg=' + info);
            } catch (e) {}
        });
    });
    hook('FlutterMethodChannel', '- setMethodCallHandler:', function (args) {
        try { console.log('[bridge] handler set on channel ' +
                          channelName(new ObjC.Object(args[0]))); } catch (e) {}
    });

    // 4) Backend submission (authoritative liveness decision: /createProcess).
    ['- dataTaskWithRequest:completionHandler:',
     '- uploadTaskWithRequest:fromData:completionHandler:',
     '- dataTaskWithRequest:'].forEach(function (sel) {
        hook('NSURLSession', sel, function (args) {
            try {
                const req = new ObjC.Object(args[2]);
                const url = req.URL().absoluteString().toString();
                console.log('[net] ' + url);
                if (url.indexOf('createProcess') !== -1)
                    console.log('[net]   ^ liveness decision endpoint');
            } catch (e) {}
        });
    });

    // 5) JWT capture — grab it the moment "COPY JWT" writes to the pasteboard.
    hook('UIPasteboard', '- setString:', function (args) {
        try {
            const s = new ObjC.Object(args[2]).toString();
            if (s.indexOf('eyJ') === 0 || s.split('.').length === 3) {
                console.log('[jwt] captured from pasteboard:\n' + s);
            }
        } catch (e) {}
    });

    console.log('[recon] hooks installed — run a LIVENESS CAMERA capture, then COPY JWT.');
}
