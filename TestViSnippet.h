#import <SenTestingKit/SenTestingKit.h>
#import "ViSnippet.h"

@interface TestViSnippet : SenTestCase
{
	NSDictionary *env;
	NSError *err;
	id<ViSnippetDelegate> delegate;
	ViSnippet *snippet;
}

@end