#ifndef MT_GUARD_H
#define MT_GUARD_H

// mt_guard_run seizes the AJAZZ receiver's keyboard and/or consumer-control HID
// interfaces so macOS never sees the input they emit, and reports everything
// they send back to Go. It blocks in a CFRunLoop until mt_guard_stop is called.
//
// vendorID       USB vendor ID to accept (0 = match on name only)
// seizeKeyboard  non-zero to claim interfaces whose primary usage is Keyboard/Keypad
// seizeConsumer  non-zero to claim interfaces whose primary usage page is Consumer
// dryRun         non-zero to observe without claiming (events still reach macOS)
//
// Returns 0 on clean shutdown, or a negative/IOReturn value on failure.
int mt_guard_run(int vendorID, int seizeKeyboard, int seizeConsumer, int dryRun);

// mt_guard_stop stops the run loop started by mt_guard_run. Safe to call from
// another thread.
void mt_guard_stop(void);

#endif
