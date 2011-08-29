#import "ViMap.h"
#import "ViError.h"
#import "NSString-scopeSelector.h"
#import "NSString-additions.h"
#import "NSArray-patterns.h"
#import "ViAppController.h"
#include "logging.h"

@implementation ViMapping

@synthesize scopeSelector;
@synthesize keySequence;
@synthesize keyString;
@synthesize action;
@synthesize flags;
@synthesize recursive;
@synthesize macro;
@synthesize parameter;
@synthesize expression;

+ (ViMapping *)mappingWithKeySequence:(NSArray *)aKeySequence
			       action:(SEL)anAction
				flags:(NSUInteger)flags
			    parameter:(id)param
				scope:(NSString *)aSelector
{
	return [[ViMapping alloc] initWithKeySequence:aKeySequence
					       action:anAction
					        flags:flags
					    parameter:param
					        scope:aSelector];
}

+ (ViMapping *)mappingWithKeySequence:(NSArray *)aKeySequence
				macro:(NSString *)aMacro
			    recursive:(BOOL)recursiveFlag
				scope:(NSString *)aSelector
{
	return [[ViMapping alloc] initWithKeySequence:aKeySequence
						macro:aMacro
					    recursive:recursiveFlag
					        scope:aSelector];
}

+ (ViMapping *)mappingWithKeySequence:(NSArray *)aKeySequence
			   expression:(NuBlock *)expr
				scope:(NSString *)aSelector
{
	return [[ViMapping alloc] initWithKeySequence:aKeySequence
					   expression:expr
					        scope:aSelector];
}

- (ViMapping *)initWithKeySequence:(NSArray *)aKeySequence
			    action:(SEL)anAction
			     flags:(NSUInteger)actionFlags
			 parameter:(id)param
			     scope:(NSString *)aSelector
{
	if ((self = [super init]) != nil) {
		keySequence = aKeySequence;
		action = anAction;
		flags = actionFlags;
		scopeSelector = aSelector ? [aSelector copy] : @"";
		keyString = [NSString stringWithKeySequence:keySequence];
		parameter = param;
	}
	return self;
}

- (ViMapping *)initWithKeySequence:(NSArray *)aKeySequence
			     macro:(NSString *)aMacro
			 recursive:(BOOL)recursiveFlag
			     scope:(NSString *)aSelector
{
	if ((self = [super init]) != nil) {
		keySequence = aKeySequence;
		macro = [aMacro copy];
		recursive = recursiveFlag;
		scopeSelector = aSelector ? [aSelector copy] : @"";
		keyString = [NSString stringWithKeySequence:keySequence];
	}
	return self;
}

- (ViMapping *)initWithKeySequence:(NSArray *)aKeySequence
			expression:(NuBlock *)anExpression
			     scope:(NSString *)aSelector
{
	if ((self = [super init]) != nil) {
		keySequence = aKeySequence;
		expression = anExpression;
		recursive = NO;
		scopeSelector = aSelector ? [aSelector copy] : @"";
		keyString = [NSString stringWithKeySequence:keySequence];
	}
	return self;
}

#define has_flag(flag) ((flags & flag) == flag)

- (BOOL)isAction
{
	return macro == nil && expression == nil;
}

- (BOOL)isMacro
{
	return macro != nil || expression != nil;
}

- (BOOL)isExpression
{
	return !!expression;
}

- (BOOL)isOperator
{
	return has_flag(ViMapNeedMotion);
}

- (BOOL)isMotion
{
	return has_flag(ViMapIsMotion);
}

- (BOOL)isLineMode
{
	return has_flag(ViMapLineMode);
}

- (BOOL)needsArgument
{
	return has_flag(ViMapNeedArgument);
}

- (BOOL)wantsKeys
{
	return [self isOperator] || [self needsArgument];
}

- (NSString *)description
{
	if ([self isAction])
		return [NSString stringWithFormat:@"<ViMapping %@: \"%@\", flags 0x%02x>",
		    keyString, NSStringFromSelector(action), flags];
	else if ([self isExpression])
		return [NSString stringWithFormat:@"<ViMapping %@: nu expression>",
		    keyString];
	else
		return [NSString stringWithFormat:@"<ViMapping %@: macro \"%@\">",
		    keyString, macro];
}

@end

@implementation ViMap

@synthesize name;
@synthesize actions;
@synthesize operatorMap;
@synthesize acceptsCounts;
@synthesize defaultAction;

static NSMutableDictionary *maps = nil;

+ (void)clearAll
{
	maps = nil;
}

+ (NSArray *)allMaps
{
	return [maps allValues];
}

+ (ViMap *)mapWithName:(NSString *)mapName
{
	if (maps == nil)
		maps = [NSMutableDictionary dictionary];

	ViMap *map = [maps objectForKey:mapName];
	if (map == nil) {
		map = [[ViMap alloc] initWithName:mapName];
		[maps setObject:map forKey:mapName];
	}

	return map;
}

+ (ViMap *)insertMap
{
	return [ViMap mapWithName:@"insertMap"];
}

+ (ViMap *)normalMap
{
	return [ViMap mapWithName:@"normalMap"];
}

+ (ViMap *)operatorMap
{
	return [ViMap mapWithName:@"operatorMap"];
}

+ (ViMap *)visualMap
{
	return [ViMap mapWithName:@"visualMap"];
}

+ (ViMap *)explorerMap
{
	return [ViMap mapWithName:@"explorerMap"];
}

+ (ViMap *)symbolMap
{
	return [ViMap mapWithName:@"symbolMap"];
}

+ (ViMap *)completionMap
{
	return [ViMap mapWithName:@"completionMap"];
}

- (ViMap *)initWithName:(NSString *)aName
{
	if ((self = [super init]) != nil) {
		name = aName;
		actions = [NSMutableArray array];
		includes = [NSMutableSet set];
		acceptsCounts = YES;
	}
	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<ViMap %@, %lu actions>",
	    name, [actions count]];
}

- (ViMapping *)lookupKeySequence:(NSArray *)keySequence
                          inMaps:(NSArray *)maps
                       withScope:(ViScope *)scope
                     allowMacros:(BOOL)allowMacros
                      excessKeys:(NSArray **)excessKeys
                         timeout:(BOOL *)timeout
                           error:(NSError **)outError
{
	ViMapping *candidate = nil;
	ViMapping *exact_candidate = nil;
	ViMap *exact_candidate_map = nil; /* map of the exact_candidate */
	u_int64_t exact_candidate_rank = 0;
	ViMapping *op = nil; /* fully matched operator */
	NSUInteger len = [keySequence count];
	BOOL gotMultipleCandidates = NO;
	for (ViMap *map in maps) {
		for (ViMapping *m in map.actions) {
			if (!allowMacros && [m isMacro])
				continue;

			NSUInteger mlen = [m.keySequence count];
			NSUInteger i;
			for (i = 0; i < len && i < mlen; i++)
				if (![[keySequence objectAtIndex:i] isEqual:[m.keySequence objectAtIndex:i]])
					break;
			if (i < len && i < mlen)
				/* Not enough keys in common. No match. */
				continue;

			BOOL partialOrEqualMatch = (mlen >= len);
			BOOL overflowOrEqualMatch = (len >= mlen);
			BOOL equalMatch = (len == mlen);

			/* FIXME: compare rank of all matches */
			u_int64_t rank = [m.scopeSelector match:scope];
			if (rank == 0)
				continue;

			DEBUG(@"testing key [%@] against %@ (%s) for selector %@ w/rank %llu in scope %@",
			     keySequence, m,
			     equalMatch ? "EQUAL" : (partialOrEqualMatch ? "PART+EQUAL" : "OVERFLOW+EQUAL"),
			     m.scopeSelector, rank, scope);

			if (overflowOrEqualMatch && [m wantsKeys]) {
				/*
				 * We found an action that requires additional (dynamic) keys.
				 * Remember the most significant match. If no other mapping
				 * matches, we return this operator and the excess keys back
				 * to the parser (which will try to map them to motion commands).
				 */
				if (mlen > [op.keySequence count]) {
					op = m;
					DEBUG(@"got operator candidate %@", op);
				}
			} else if ((equalMatch || overflowOrEqualMatch) && ![m wantsKeys]) {
				/*
				 * If we get an exact match, but there are longer key
				 * sequences that might match if we get more keys, we
				 * set a timeout and then go with the exact match.
				 * Only do this if the exact match doesn't require
				 * additional keys, because in that case we must wait
				 * for keys anyway.
				 */
				if (exact_candidate) {
					/*
					 * We should not get duplicates inside a single map as we make
					 * sure there are no duplicate key sequences of the same type
					 * that either does or does not require additional keys.
					 *
					 * However, since we iterate over multiple included maps,
					 * we might now get duplicates between maps.
					 *
					 * We solve this by making actions in included maps be
					 * overridden by higher-level maps.
					 *
					 * Should included macros still be preferred over actions?
					 */

					if (rank > exact_candidate_rank) {
						DEBUG(@"%@ in map %@ w/rank %llu overrides %@ in map %@ w/rank %llu",
						    m, map, rank,
						    exact_candidate, exact_candidate_map, exact_candidate_rank);
						if (candidate == exact_candidate)
							candidate = nil;
						exact_candidate = nil;
					} else if (map == exact_candidate_map) {
						if ([exact_candidate isAction] == [m isAction]) {
							INFO(@"Ouch! already got an exact match %@ in map %@",
							    exact_candidate, map);
							if (outError)
								*outError = [ViError
								    errorWithCode:ViErrorMapInternal
									   format:@"Duplicate mapping %@.",
									       [m keyString]];
							return nil;
						}
						/*
						 * Otherwise we let macros override regular
						 * actions within the same map.
						 */
					} else if ([exact_candidate_map includesMap:map]) {
						/* This map is a sub-map of the found candidate map. */
						DEBUG(@"%@ in map %@ overrides %@ in map %@",
						    exact_candidate, exact_candidate_map,
						    m, map);
						continue;
					} else {
						/* This map is a super-map of the found candidate map. */
						DEBUG(@"%@ in map %@ overrides %@ in map %@",
						    m, map,
						    exact_candidate, exact_candidate_map);
						exact_candidate = nil;
					}
				}

				if (exact_candidate == nil ||
					/* Macros override regular actions. */
				    ([exact_candidate isAction] && [m isMacro])) {
					DEBUG(@"got exact candidate %@", m);
					exact_candidate = m;
					exact_candidate_map = map;
					exact_candidate_rank = rank;
				}
			}

			/* Check for possibly partial matches. */
			if (partialOrEqualMatch) {
				DEBUG(@"got candidate %@", m);
				/*
				 * Check for a macro overriding an action with the same key sequence.
				 */
				if (candidate &&
				    mlen == [candidate.keySequence count] &&
				    [m isAction] != [candidate isAction]) {
					if ([m isMacro])
						candidate = m;
					continue;
				}

				if (candidate)
					gotMultipleCandidates = YES;

				if (candidate && exact_candidate) {
					/*
					 * We found an ambiguous mapping, but we have
					 * an exact match. If no other key is received
					 * without a timeout, we should return the
					 * exact match.
					 */
					if (*timeout == YES) {
						DEBUG(@"timeout: returning exact match %@",
						    exact_candidate);
						return exact_candidate;
					}
					DEBUG(@"setting timeout for exact candidate %@",
					    exact_candidate);
					*timeout = YES;

					if (outError)
						*outError = [ViError errorWithCode:ViErrorMapAmbiguous
									    format:@"Ambiguous match."];
					return nil;
				}

				candidate = m;
			}
		}
	}

	if (candidate == nil && op != nil) {
		NSUInteger oplen = [op.keySequence count];
		NSRange r = NSMakeRange(oplen, len - oplen);
		if (excessKeys)
			*excessKeys = [keySequence subarrayWithRange:r];
		DEBUG(@"mapped [%@] to %@ with excess keys [%@]",
		    keySequence, op, excessKeys ? *excessKeys : @"discarded");
		return op;
	}

	if (candidate == nil && exact_candidate != nil) {
		NSUInteger eclen = [exact_candidate.keySequence count];
		NSRange r = NSMakeRange(eclen, len - eclen);
		if (excessKeys)
			*excessKeys = [keySequence subarrayWithRange:r];
		DEBUG(@"mapped [%@] to %@ with excess keys [%@]",
		    keySequence, exact_candidate, excessKeys ? *excessKeys : @"discarded");
		return exact_candidate;
	}

	/*
	 * Problem: if there is an operator and another mapping with the same
	 * prefix as the operator, we need to decide whether the keys after the
	 * prefix is a motion for the operator, or a specialization of another
	 * mapping.
	 *
	 * When we know this, it's sort of too late to match the operator,
	 * and we need to backtrack and return the excess keys back to the parser
	 * to check for a motion command.
	 */

	/*
	 * Not only operators might need to return excess keys, but also actions
	 * with arguments!
	 */

	if (candidate == nil && outError)
		*outError = [ViError errorWithCode:ViErrorMapNotFound
					    format:@"%@ is not mapped.", [NSString stringWithKeySequence:keySequence]];

	if (gotMultipleCandidates) {
		DEBUG(@"%s", "multiple matches, need more keys");
		if (outError)
			*outError = [ViError errorWithCode:ViErrorMapAmbiguous
						    format:@"Ambiguous match."];
		return nil;
	}

	if (candidate && len != [candidate.keySequence count]) {
		DEBUG(@"%@ is partial match, need more keys", candidate);
		if (outError)
			*outError = [ViError errorWithCode:ViErrorMapAmbiguous
						    format:@"Ambiguous match."];
		return nil;
	}

	return candidate;
}

- (BOOL)includesMap:(ViMap *)aMap
{
	if ([includes containsObject:aMap])
		return YES;
	for (ViMap *map in includes)
		if ([map includesMap:aMap])
			return YES;
	return NO;
}

- (void)resolveIncludedMaps:(NSMutableArray *)includeMaps
{
	for (ViMap *m in includes) {
		DEBUG(@"adding included map %@", m);
		[includeMaps addObject:m];
		[m resolveIncludedMaps:includeMaps];
	}
}

- (ViMapping *)lookupKeySequence:(NSArray *)keySequence
                       withScope:(ViScope *)scope
                     allowMacros:(BOOL)allowMacros
                      excessKeys:(NSArray **)excessKeys
                         timeout:(BOOL *)timeoutPtr
                           error:(NSError **)outError
{
	ViMapping *m = nil;

	NSMutableArray *resolved = [NSMutableArray arrayWithObject:self];
	[self resolveIncludedMaps:resolved];

	DEBUG(@"looking up [%@] in maps %@, %sincluding macros",
	    keySequence, resolved, allowMacros ? "" : "NOT ");

	NSError *error = nil;
	m = [self lookupKeySequence:keySequence
			     inMaps:resolved
			  withScope:scope
			allowMacros:allowMacros
			 excessKeys:excessKeys
			    timeout:timeoutPtr
			      error:&error];

	if (outError && error.code != ViErrorMapAmbiguous)
		*outError = error;

	if (m == nil) {
		if (error.code == ViErrorMapNotFound && defaultAction &&
		    [[keySequence objectAtIndex:0] integerValue] < 0xFFFF) {
			/* Nothing matched. Return the default action, if there is one. */
			if (outError)
				*outError = nil;
			m = [ViMapping mappingWithKeySequence:keySequence
						       action:defaultAction
						        flags:0
						    parameter:nil
						        scope:nil];
			DEBUG(@"using default action %@", m);
			return m;
		}
	}

	DEBUG(@"found action %@", m);

	return m;
}

- (void)addMapping:(ViMapping *)nm
{
	for (ViMapping *m in actions)
		if ([m.keySequence isEqual:nm.keySequence] &&
		    [m.scopeSelector isEqualToString:nm.scopeSelector] &&
		    [m isAction] == [nm isAction] &&
		    (![m isAction] ||
		     ([m wantsKeys] == [nm wantsKeys]))) {
			[actions removeObject:m];
			break;
		}

	[actions addObject:nm];
	DEBUG(@"added mapping %@", nm);
}

- (void)map:(NSString *)keySequence
         to:(NSString *)macro
recursively:(BOOL)recursiveFlag
      scope:(NSString *)scopeSelector
{
	NSArray *keyCodes = [keySequence keyCodes];
	if (keyCodes == nil) {
		INFO(@"invalid key sequence: %@", keySequence);
		return;
	}
	[self addMapping:[ViMapping mappingWithKeySequence:keyCodes
						     macro:macro
						 recursive:recursiveFlag
						     scope:scopeSelector]];
}

- (void)map:(NSString *)keySequence
         to:(NSString *)macro
      scope:(NSString *)scopeSelector
{
	[self map:keySequence
	       to:macro
      recursively:NO
	    scope:scopeSelector];
}

- (void)map:(NSString *)keySequence
         to:(NSString *)macro
{
	[self map:keySequence
	       to:macro
      recursively:NO
	    scope:nil];
}

- (void)map:(NSString *)keySequence
toExpression:(id)expr
      scope:(NSString *)scopeSelector
{
	NSArray *keyCodes = [keySequence keyCodes];
	if (keyCodes == nil) {
		INFO(@"invalid key sequence: %@", keySequence);
		return;
	}

	if (![expr isKindOfClass:[NuBlock class]]) {
		INFO(@"unhandled expression of type %@", NSStringFromClass([expr class]));
		return;
	}

	if ([[expr parameters] count] > 0) {
		INFO(@"parameters %@ will be ignored in expression map %@",
		    [[expr parameters] stringValue], keySequence);
	}

	[self addMapping:[ViMapping mappingWithKeySequence:keyCodes
						expression:expr
						     scope:scopeSelector]];
}

- (void)map:(NSString *)keySequence
toExpression:(id)expr
{
	[self map:keySequence toExpression:expr scope:nil];
}

- (void)unmap:(NSString *)keySequence
        scope:(NSString *)scopeSelector
{
	NSArray *keyCodes = [keySequence keyCodes];
	if (keyCodes == nil) {
		INFO(@"invalid key sequence: %@", keySequence);
		return;
	}

	for (ViMapping *m in actions)
		if ([m.keySequence isEqual:keyCodes] &&
		    [m.scopeSelector isEqualToString:(scopeSelector ?: @"")] &&
		    [m isMacro]) {
			[actions removeObject:m];
			break;
		}
}

- (void)unmap:(NSString *)keySequence
{
	[self unmap:keySequence scope:nil];
}

- (void)unset:(NSString *)keySequence
        scope:(NSString *)scopeSelector
{
	NSArray *keyCodes = [keySequence keyCodes];
	if (keyCodes == nil) {
		INFO(@"invalid key sequence: %@", keySequence);
		return;
	}

	for (ViMapping *m in actions)
		if ([m.keySequence isEqual:keyCodes] &&
		    [m.scopeSelector isEqualToString:(scopeSelector ?: @"")] &&
		    ![m isMacro]) {
			[actions removeObject:m];
			break;
		}
}

- (void)unset:(NSString *)keySequence
{
	[self unset:keySequence scope:nil];
}

- (void)setKey:(NSString *)keySequence
      toAction:(SEL)selector
         flags:(NSUInteger)flags
     parameter:(id)param
         scope:(NSString *)scopeSelector
{
	NSArray *keyCodes = [keySequence keyCodes];
	if (keyCodes == nil) {
		INFO(@"invalid key sequence: %@", keySequence);
		return;
	}
	[self addMapping:[ViMapping mappingWithKeySequence:keyCodes
						    action:selector
						     flags:flags
						 parameter:param
						     scope:scopeSelector]];
}

- (void)setKey:(NSString *)keySequence
      toAction:(SEL)selector
{
	[self setKey:keySequence
	    toAction:selector
	       flags:0
	   parameter:nil
	       scope:nil];
}

- (void)setKey:(NSString *)keySequence
      toMotion:(SEL)selector
         flags:(NSUInteger)flags
     parameter:(id)param
         scope:(NSString *)scopeSelector
{
	[self setKey:keySequence
	    toAction:selector
	       flags:flags|ViMapIsMotion
	   parameter:param
	       scope:scopeSelector];
}

- (void)setKey:(NSString *)keySequence
      toMotion:(SEL)selector
{
	[self setKey:keySequence
	    toMotion:selector
	       flags:0
	   parameter:nil
	       scope:nil];
}

- (void)setKey:(NSString *)keySequence
  toEditAction:(SEL)selector
         flags:(NSUInteger)flags
     parameter:(id)param
         scope:(NSString *)scopeSelector
{
	[self setKey:keySequence
	    toAction:selector
	       flags:flags|ViMapSetsDot
	   parameter:param
	       scope:scopeSelector];
}

- (void)setKey:(NSString *)keySequence
  toEditAction:(SEL)selector
{
	[self setKey:keySequence
	toEditAction:selector
	       flags:0
	   parameter:nil
	       scope:nil];
}

- (void)setKey:(NSString *)keySequence
    toOperator:(SEL)selector
         flags:(NSUInteger)flags
     parameter:(id)param
         scope:(NSString *)scopeSelector
{
	[self setKey:keySequence
	toEditAction:selector
	       flags:flags|ViMapNeedMotion
	   parameter:param
	       scope:scopeSelector];
}

- (void)setKey:(NSString *)keySequence
    toOperator:(SEL)selector
{
	[self setKey:keySequence
	  toOperator:selector
	       flags:0
	   parameter:nil
	       scope:nil];
}

- (void)include:(ViMap *)map
{
	DEBUG(@"including map %@ in map %@", map, self);
	[includes addObject:map];
}

@end
