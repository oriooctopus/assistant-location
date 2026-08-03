#import "GLFormat.h"

NSString *GLFormatDuration(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)MAX(seconds, 0);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total / 60) % 60;
    NSInteger secs = total % 60;
    if (hours == 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
}

NSString *GLFilenameTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd-HHmmss";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}
