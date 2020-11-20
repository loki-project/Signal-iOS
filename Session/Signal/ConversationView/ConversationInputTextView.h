//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import <SignalUtilitiesKit/OWSTextView.h>

NS_ASSUME_NONNULL_BEGIN

@class SignalAttachment;

@protocol ConversationInputTextViewDelegate <NSObject>

- (void)didPasteAttachment:(SignalAttachment *_Nullable)attachment;

- (void)inputTextViewSendMessagePressed;

- (void)textViewDidChange:(UITextView *)textView;

@end

#pragma mark -

@protocol ConversationTextViewToolbarDelegate <NSObject>

- (void)textViewDidChange:(UITextView *)textView;
- (void)textViewDidChangeSelection:(UITextView *)textView;

@end

#pragma mark -

@interface ConversationInputTextView : OWSTextView

@property (weak, nonatomic) id<ConversationInputTextViewDelegate> inputTextViewDelegate;

@property (weak, nonatomic) id<ConversationTextViewToolbarDelegate> textViewToolbarDelegate;

- (NSString *)trimmedText;
- (void)setPlaceholderText:(NSString *)placeholderText;

@end

NS_ASSUME_NONNULL_END
