#import "CBBlueLightClient.h"

CBBlueLightClient *makeClient(void);
BOOL readStrength(CBBlueLightClient *client, long *stored);
BOOL applyStrength(CBBlueLightClient *client, long value, long *stored);
