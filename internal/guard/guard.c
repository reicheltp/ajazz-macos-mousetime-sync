#include "guard.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <string.h>

// Implemented in Go (see guard_darwin.go).
extern void mtGuardEvent(int vendorID, int productID, int usagePage, int usage,
                         int value);
extern void mtGuardDevice(int vendorID, int productID, int usagePage, int usage,
                          const char *product, int seized);

static IOHIDManagerRef gManager;
static CFRunLoopRef gLoop;
static int gVendorID;
static int gSeizeKeyboard;
static int gSeizeConsumer;
static int gDryRun;

static int propInt(IOHIDDeviceRef d, CFStringRef key) {
  CFTypeRef p = IOHIDDeviceGetProperty(d, key);
  int v = 0;
  if (p && CFGetTypeID(p) == CFNumberGetTypeID()) {
    CFNumberGetValue((CFNumberRef)p, kCFNumberIntType, &v);
  }
  return v;
}

static void propStr(IOHIDDeviceRef d, CFStringRef key, char *out, size_t n) {
  out[0] = '\0';
  CFTypeRef p = IOHIDDeviceGetProperty(d, key);
  if (p && CFGetTypeID(p) == CFStringGetTypeID()) {
    CFStringGetCString((CFStringRef)p, out, (CFIndex)n, kCFStringEncodingUTF8);
  }
}

static void inputCB(void *ctx, IOReturn result, void *sender,
                    IOHIDValueRef value) {
  if (result != kIOReturnSuccess || sender == NULL) {
    return;
  }
  IOHIDElementRef el = IOHIDValueGetElement(value);
  if (el == NULL) {
    return;
  }
  IOHIDDeviceRef dev = (IOHIDDeviceRef)sender;
  mtGuardEvent(propInt(dev, CFSTR(kIOHIDVendorIDKey)),
               propInt(dev, CFSTR(kIOHIDProductIDKey)),
               (int)IOHIDElementGetUsagePage(el), (int)IOHIDElementGetUsage(el),
               (int)IOHIDValueGetIntegerValue(value));
}

// shouldGuard decides whether an interface is one of the phantom-input
// offenders. It deliberately refuses to claim the pointing device: seizing that
// would stop the mouse from working, which is the opposite of the goal.
static int shouldGuard(IOHIDDeviceRef d, int *outPage, int *outUsage) {
  char product[256];
  char mfr[256];
  propStr(d, CFSTR(kIOHIDProductKey), product, sizeof product);
  propStr(d, CFSTR(kIOHIDManufacturerKey), mfr, sizeof mfr);

  int vid = propInt(d, CFSTR(kIOHIDVendorIDKey));
  int isAjazz = (gVendorID != 0 && vid == gVendorID) ||
                strcasestr(product, "ajazz") != NULL ||
                strcasestr(mfr, "ajazz") != NULL;

  int page = propInt(d, CFSTR(kIOHIDPrimaryUsagePageKey));
  int usage = propInt(d, CFSTR(kIOHIDPrimaryUsageKey));
  *outPage = page;
  *outUsage = usage;

  if (!isAjazz) {
    return 0;
  }
  if (page == kHIDPage_GenericDesktop &&
      (usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer)) {
    return 0;
  }
  if (gSeizeKeyboard && page == kHIDPage_GenericDesktop &&
      (usage == kHIDUsage_GD_Keyboard || usage == kHIDUsage_GD_Keypad)) {
    return 1;
  }
  if (gSeizeConsumer && page == kHIDPage_Consumer) {
    return 1;
  }
  return 0;
}

static void attach(IOHIDDeviceRef d) {
  int page = 0;
  int usage = 0;
  if (!shouldGuard(d, &page, &usage)) {
    return;
  }

  IOOptionBits opts =
      gDryRun ? kIOHIDOptionsTypeNone : kIOHIDOptionsTypeSeizeDevice;
  IOReturn r = IOHIDDeviceOpen(d, opts);

  char product[256];
  propStr(d, CFSTR(kIOHIDProductKey), product, sizeof product);
  mtGuardDevice(propInt(d, CFSTR(kIOHIDVendorIDKey)),
                propInt(d, CFSTR(kIOHIDProductIDKey)), page, usage, product,
                r == kIOReturnSuccess);

  if (r != kIOReturnSuccess) {
    return;
  }
  IOHIDDeviceRegisterInputValueCallback(d, inputCB, NULL);
  IOHIDDeviceScheduleWithRunLoop(d, gLoop, kCFRunLoopDefaultMode);
}

static void matchCB(void *ctx, IOReturn result, void *sender,
                    IOHIDDeviceRef d) {
  attach(d);
}

int mt_guard_run(int vendorID, int seizeKeyboard, int seizeConsumer,
                 int dryRun) {
  gVendorID = vendorID;
  gSeizeKeyboard = seizeKeyboard;
  gSeizeConsumer = seizeConsumer;
  gDryRun = dryRun;
  gLoop = CFRunLoopGetCurrent();

  gManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  if (gManager == NULL) {
    return -1;
  }

  // Match everything, then filter in shouldGuard: the interesting interfaces
  // are identified by name plus primary usage, which a matching dictionary
  // cannot express (it has no substring predicate).
  IOHIDManagerSetDeviceMatching(gManager, NULL);
  IOHIDManagerRegisterDeviceMatchingCallback(gManager, matchCB, NULL);
  IOHIDManagerScheduleWithRunLoop(gManager, gLoop, kCFRunLoopDefaultMode);

  // The matching callback fires for devices already attached, so this covers
  // both the startup scan and later hotplugs.
  IOReturn r = IOHIDManagerOpen(gManager, kIOHIDOptionsTypeNone);
  if (r != kIOReturnSuccess) {
    return (int)r;
  }

  CFRunLoopRun();

  IOHIDManagerClose(gManager, kIOHIDOptionsTypeNone);
  return 0;
}

void mt_guard_stop(void) {
  if (gLoop != NULL) {
    CFRunLoopStop(gLoop);
  }
}
