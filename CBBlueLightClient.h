# import <Foundation/Foundation.h>

@interface CBBlueLightClient: NSObject
- (BOOL)setStrength:(float)strength commit: (BOOL)commit;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)getStrength:(float *)strength;
@end
