// GLLaunchMark(phase) — one NSLog line per named cold-launch phase, timed
// against the actual process start (not first call), so dyld/pre-main time
// is included in phase 0's delta. Measurement only: this file does not
// change app behavior, only observes it.
//
// Header-only (no GLLaunchTrace.m), same reason as Shared/GLEndpoints.h:
// Shared/ is an individually-listed group in Overland.xcodeproj/project.pbxproj,
// not a file-system-synchronized one, so a new .m would need a manual Sources
// build-phase entry. A static inline function needs no Sources entry — only
// the header search path, which already covers Shared/ for the app target.
//
// Output format is fixed and deliberately grep/sort-friendly:
//   GLLAUNCH t=%8.1fms phase=%@
// A distinctive "GLLAUNCH" prefix that appears nowhere else in the codebase,
// so `grep GLLAUNCH` on the device/simulator log gives exactly these lines
// and nothing else.

#import <Foundation/Foundation.h>
#import <sys/sysctl.h>

NS_ASSUME_NONNULL_BEGIN

/// Process start time (kernel's kinfo_proc.kp_proc.p_starttime), fetched once
/// via sysctl KERN_PROC/KERN_PROC_PID on getpid(). This is the true process
/// launch instant — earlier than anything a static initializer or +load can
/// observe — so marks taken against it include dyld/pre-main time.
NS_INLINE struct timeval GLLaunchProcessStartTime(void) {
    static struct timeval startTime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
        struct kinfo_proc info;
        size_t size = sizeof(info);
        if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
            startTime = info.kp_proc.p_starttime;
        } else {
            // Fall back to "now" rather than reporting a bogus t=0 baseline
            // if the sysctl ever fails; still monotonic within this launch.
            gettimeofday(&startTime, NULL);
        }
    });
    return startTime;
}

/// Emits one GLLAUNCH line: milliseconds since process start, plus phase name.
NS_INLINE void GLLaunchMark(NSString *phase) {
    struct timeval start = GLLaunchProcessStartTime();
    struct timeval now;
    gettimeofday(&now, NULL);
    double elapsedMs = (now.tv_sec - start.tv_sec) * 1000.0 +
                        (now.tv_usec - start.tv_usec) / 1000.0;
    NSLog(@"GLLAUNCH t=%8.1fms phase=%@", elapsedMs, phase);
}

NS_ASSUME_NONNULL_END
