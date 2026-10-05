#import "ListenRewind.h"

static NSArray<NSString *> *ListenRewindKinds(void) {
    return @[@"vocab", @"clear", @"translation", @"original"];
}

@implementation ListenRewind

+ (NSInteger)maxPresets { return 4; }

+ (NSArray<NSDictionary *> *)defaultPresets {
    return @[@{@"steps": @[@"translation", @"original"], @"slow": @0}];
}

+ (NSArray<NSDictionary *> *)presetsInSettings:(NSDictionary *)settings {
    id rewinds = settings[@"rewinds"];
    return rewinds ? rewinds : [self defaultPresets];
}

+ (NSString *)validateSteps:(id)steps slow:(id)slow {
    if (![steps isKindOfClass:[NSArray class]] || [(NSArray *)steps count] == 0) return @"steps: expected a non-empty array";
    for (id k in steps) {
        if (![k isKindOfClass:[NSString class]] || ![ListenRewindKinds() containsObject:k]) {
            return [NSString stringWithFormat:@"unknown rewind kind %@", k];
        }
    }
    if (![slow isKindOfClass:[NSNumber class]] || [slow doubleValue] != (double)[slow integerValue] ||
        [slow integerValue] < 0 || [slow integerValue] > 50) {
        return [NSString stringWithFormat:@"slow %@ must be an int 0-50", slow];
    }
    return nil;
}

+ (NSString *)validatePresets:(id)value {
    if (![value isKindOfClass:[NSArray class]] || [(NSArray *)value count] < 1 || (NSInteger)[(NSArray *)value count] > [self maxPresets]) {
        return [NSString stringWithFormat:@"settings.rewinds: expected 1...%ld presets", (long)[self maxPresets]];
    }
    NSUInteger i = 0;
    for (id preset in value) {
        if (![preset isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"settings.rewinds[%lu]: expected an object", (unsigned long)i];
        NSString *error = [self validateSteps:preset[@"steps"] slow:preset[@"slow"]];
        if (error) return [NSString stringWithFormat:@"settings.rewinds[%lu]: %@", (unsigned long)i, error];
        i++;
    }
    return nil;
}

+ (NSArray<NSString *> *)playableKindsForSteps:(NSArray<NSString *> *)steps hasVocab:(BOOL)hasVocab {
    NSMutableArray *kinds = [NSMutableArray array];
    for (NSString *k in steps) {
        if ([k isEqual:@"vocab"] && !hasVocab) continue;
        [kinds addObject:k];
    }
    return kinds;
}

+ (NSString *)nameForSteps:(NSArray<NSString *> *)steps slow:(NSInteger)slow {
    NSDictionary *labels = @{@"vocab": @"Vocab", @"clear": @"Clear", @"translation": @"English", @"original": @"Original"};
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in steps) [parts addObject:labels[k]];
    NSString *base = [parts componentsJoinedByString:@" → "];
    if (slow == 0) return base;
    if (steps.count == 1 && [steps[0] isEqual:@"original"]) return [NSString stringWithFormat:@"Original %ld%% slower", (long)slow];
    return [NSString stringWithFormat:@"%@ (original %ld%% slower)", base, (long)slow];
}

@end
