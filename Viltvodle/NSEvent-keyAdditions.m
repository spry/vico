#import "NSEvent-keyAdditions.h"
#include "logging.h"

@implementation NSEvent (keyAdditions)

- (NSInteger)normalizedKeyCode
{
	// http://sigpipe.macromates.com/2005/09/24/deciphering-an-nsevent/
	// given theEvent (NSEvent*) figure out what key 
	// and modifiers we actually want to look at, 
	// to compare it with a menu key description

	NSUInteger quals = [self modifierFlags];

	NSString *str = [self characters];
	NSString *strWithout = [self charactersIgnoringModifiers];

	DEBUG(@"length = %lu / %lu", [str length], [strWithout length]);
	if ([str length] == 0) {
		/*
		 * This is not a complete key. Could be a dead key or some
		 * non-western input method thingy.
		 */
		return -1;
	}

	unichar ch = [str length] ? [str characterAtIndex:0] : 0;
	unichar key = ch;
	unichar without = [strWithout length] ? [strWithout characterAtIndex:0] : 0;

	DEBUG(@"decoding event %@", self);

	if (!(quals & NSNumericPadKeyMask)) {
		if ((quals & NSControlKeyMask)) {
			if (key < 0x20 && ((key != 0x1B && key != 0x0D && key != 0x09) || key != without) &&
			    (quals & NSDeviceIndependentModifierFlagsMask) == NSControlKeyMask)
				/* only control pressed */
				quals = 0;
			else
				key = without;
		} else if (quals & NSAlternateKeyMask) {
			if (0x20 < key && key < 0x7f && key != without)
				quals &= ~NSAlternateKeyMask;
			else
				key = without;
		} else if ((quals & (NSCommandKeyMask | NSShiftKeyMask)) == (NSCommandKeyMask | NSShiftKeyMask))
			key = without;

		if ((0x20 < key && key < 0x7f) || key == 0x19 || key == 0x1E)
			quals &= ~NSShiftKeyMask;
	}

	if (key > 0 && key < 0x20 && key != 0x1B && key != 0x0D && key != 0x09)
		quals &= ~NSControlKeyMask;
 
	unsigned int modifiers = quals & (NSShiftKeyMask | NSControlKeyMask | NSAlternateKeyMask | NSCommandKeyMask);

	NSInteger enc = (modifiers | key);
	DEBUG(@"key = %C (0x%04x / 0x%04x -> 0x%04x), s=%s, c=%s, a=%s, C=%s => 0x%04x",
	    key ?: ' ', ch, without, key,
	    (modifiers & NSShiftKeyMask) ? "YES" : "NO",
	    (modifiers & NSControlKeyMask) ? "YES" : "NO",
	    (modifiers & NSAlternateKeyMask) ? "YES" : "NO",
	    (modifiers & NSCommandKeyMask) ? "YES" : "NO",
	    enc
	);

	return enc;
}

@end