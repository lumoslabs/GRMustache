// The MIT License
// 
// Copyright (c) 2012 Gwendal Roué
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "GRMustacheSectionElement_private.h"
#import "GRMustacheExpression_private.h"
#import "GRMustacheRenderingElement_private.h"
#import "GRMustacheTemplate_private.h"
#import "GRMustacheTemplateDelegate.h"
#import "GRMustacheRuntime_private.h"
#import "GRMustacheRenderer_private.h"

@interface GRMustacheSectionElement()
@property (nonatomic, retain, readonly) GRMustacheExpression *expression;

/**
 * @see +[GRMustacheSectionElement sectionElementWithExpression:templateRepository:templateString:innerRange:inverted:overridable:innerElements:]
 */
- (id)initWithExpression:(GRMustacheExpression *)expression templateRepository:(GRMustacheTemplateRepository *)templateRepository templateString:(NSString *)templateString innerRange:(NSRange)innerRange inverted:(BOOL)inverted overridable:(BOOL)overridable innerElements:(NSArray *)innerElements;
@end


@implementation GRMustacheSectionElement
@synthesize templateRepository=_templateRepository;
@synthesize expression=_expression;
@synthesize overridable=_overridable;
@synthesize inverted=_inverted;

+ (id)sectionElementWithExpression:(GRMustacheExpression *)expression templateRepository:(GRMustacheTemplateRepository *)templateRepository templateString:(NSString *)templateString innerRange:(NSRange)innerRange inverted:(BOOL)inverted overridable:(BOOL)overridable innerElements:(NSArray *)innerElements
{
    return [[[self alloc] initWithExpression:expression templateRepository:templateRepository templateString:templateString innerRange:innerRange inverted:inverted overridable:overridable innerElements:innerElements] autorelease];
}

- (void)dealloc
{
    [_expression release];
    [_templateString release];
    [_innerElements release];
    [super dealloc];
}

- (NSString *)innerTemplateString
{
    return [_templateString substringWithRange:_innerRange];
}

- (void)renderInnerElementsInBuffer:(NSMutableString *)buffer withRuntime:(GRMustacheRuntime *)runtime
{
    for (id<GRMustacheRenderingElement> element in _innerElements) {
        // element may be overriden by a GRMustacheTemplateOverride: resolve it.
        element = [runtime resolveRenderingElement:element];
        
        // render
        [element renderInBuffer:buffer withRuntime:runtime];
    }
}


#pragma mark - <GRMustacheRenderingObject>

- (NSString *)renderInRuntime:(GRMustacheRuntime *)runtime templateRepository:(GRMustacheTemplateRepository *)templateRepository forRenderingObject:(id<GRMustacheRenderingObject>)renderingObject HTMLEscaped:(BOOL *)HTMLEscaped
{
    NSMutableString *buffer = [NSMutableString string];
    [self renderInnerElementsInBuffer:buffer withRuntime:runtime];
    *HTMLEscaped = YES;
    return buffer;
}


#pragma mark - <GRMustacheRenderingElement>

- (void)renderInBuffer:(NSMutableString *)buffer withRuntime:(GRMustacheRuntime *)runtime
{
    id value = [_expression evaluateInRuntime:runtime asFilterValue:NO];
    [runtime delegateValue:value interpretation:GRMustacheSectionTagInterpretation forRenderingToken:_expression.token usingBlock:^(id value) {

        id<GRMustacheRenderingObject> renderingObject = [GRMustacheRenderer renderingObjectForValue:value];
        
        BOOL HTMLEscaped = NO;
        NSString *rendering = [renderingObject renderInRuntime:runtime
                                            templateRepository:_templateRepository
                                            forRenderingObject:self
                                                   HTMLEscaped:&HTMLEscaped];
        
        if (rendering) {
            [buffer appendString:rendering];
        }
    }];
}

- (id<GRMustacheRenderingElement>)resolveRenderingElement:(id<GRMustacheRenderingElement>)element
{
    // Only {{$...}} section can override elements
    if (!_overridable) {
        return element;
    }
    
    // {{$...}} sections can only override other sections
    if (![element isKindOfClass:[GRMustacheSectionElement class]]) {
        return element;
    }
    GRMustacheSectionElement *otherSectionElement = (GRMustacheSectionElement *)element;

    // {{$...}} sections can only override other overridable sections
    if (!otherSectionElement.isOverridable) {
        return otherSectionElement;
    }

    // {{$...}} sections can only override other sections with the same expression
    if ([otherSectionElement.expression isEqual:_expression]) {
        return self;
    }
    return otherSectionElement;
}


#pragma mark - Private

- (id)initWithExpression:(GRMustacheExpression *)expression templateRepository:(GRMustacheTemplateRepository *)templateRepository templateString:(NSString *)templateString innerRange:(NSRange)innerRange inverted:(BOOL)inverted overridable:(BOOL)overridable innerElements:(NSArray *)innerElements
{
    self = [self init];
    if (self) {
        _expression = [expression retain];
        _templateRepository = templateRepository; // do not retain, since self is retained by a template, that is retained by the template repository.
        _templateString = [templateString retain];
        _innerRange = innerRange;
        _inverted = inverted;
        _overridable = overridable;
        _innerElements = [innerElements retain];
    }
    return self;
}

@end
