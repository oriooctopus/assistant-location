// Haptic feedback helpers. No haptics exist anywhere in the app today —
// these are the three feedback generator types modules are expected to use
// instead of hand-rolling a UINotificationFeedbackGenerator/
// UIImpactFeedbackGenerator per call site.

#import <UIKit/UIKit.h>

NS_INLINE void GLHapticSuccess(void) {
    UINotificationFeedbackGenerator *generator = [[UINotificationFeedbackGenerator alloc] init];
    [generator notificationOccurred:UINotificationFeedbackTypeSuccess];
}

NS_INLINE void GLHapticWarning(void) {
    UINotificationFeedbackGenerator *generator = [[UINotificationFeedbackGenerator alloc] init];
    [generator notificationOccurred:UINotificationFeedbackTypeWarning];
}

NS_INLINE void GLHapticSelection(void) {
    UISelectionFeedbackGenerator *generator = [[UISelectionFeedbackGenerator alloc] init];
    [generator selectionChanged];
}
