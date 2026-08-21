#import "GCGTargetCell.h"
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>

static const CGFloat GCGIconPointSize = 28.0;

UIImage *GCGResizeIcon(UIImage *image){
    if(!image)return nil;
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat preferredFormat];
    format.scale=UIScreen.mainScreen.scale;
    format.opaque=NO;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(GCGIconPointSize,GCGIconPointSize) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
        [image drawInRect:CGRectMake(0,0,GCGIconPointSize,GCGIconPointSize)];
    }];
}

UIImage *GCGDaemonIcon(void){
    UIImage *image=nil;
    if(@available(iOS 13.0,*))image=[UIImage systemImageNamed:@"gearshape.2.fill"];
    return GCGResizeIcon(image);
}

@interface GCGTargetCell ()
@property(nonatomic,strong) PSSpecifier *gcgSpecifier;
@property(nonatomic,copy) NSString *gcgApplicationIdentifier;
@end

@implementation GCGTargetCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier{
    self=[super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
    if(self){self.gcgSpecifier=specifier;self.imageView.contentMode=UIViewContentModeScaleAspectFit;self.imageView.layer.cornerRadius=6;self.imageView.clipsToBounds=YES;self.detailTextLabel.textColor=UIColor.secondaryLabelColor;self.detailTextLabel.font=[UIFont systemFontOfSize:11];}
    return self;
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier{
    self.gcgSpecifier=specifier;
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *identifier=[specifier propertyForKey:@"applicationIdentifier"];
    self.gcgApplicationIdentifier=identifier;
    UIImage *supplied=[specifier propertyForKey:@"iconImage"];
    if(supplied){self.imageView.image=GCGResizeIcon(supplied);}
    else if(identifier.length){
        static NSCache *cache;static dispatch_queue_t iconQueue;static dispatch_once_t once;
        dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=160;iconQueue=dispatch_queue_create("com.moxuan.cpuoverloadkiller.icons",DISPATCH_QUEUE_SERIAL);});
        UIImage *cached=[cache objectForKey:identifier];
        if(cached)self.imageView.image=cached;
        else{
            UIImage *placeholder=nil;if(@available(iOS 13.0,*))placeholder=[UIImage systemImageNamed:@"app.fill"];
            self.imageView.image=GCGResizeIcon(placeholder);
            __weak typeof(self) weakSelf=self;NSString *requested=[identifier copy];CGFloat screenScale=UIScreen.mainScreen.scale;
            dispatch_async(iconQueue,^{
                SEL selector=NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");UIImage *icon=nil;
                if([UIImage respondsToSelector:selector]){typedef UIImage *(*Fn)(id,SEL,NSString*,NSInteger,CGFloat);icon=((Fn)objc_msgSend)(UIImage.class,selector,requested,2,screenScale);}
                dispatch_async(dispatch_get_main_queue(),^{UIImage *resized=GCGResizeIcon(icon);if(resized)[cache setObject:resized forKey:requested];if([weakSelf.gcgApplicationIdentifier isEqualToString:requested]&&resized)weakSelf.imageView.image=resized;});
            });
        }
    }else self.imageView.image=nil;
    self.detailTextLabel.text=[specifier propertyForKey:@"subtitle"];
}
- (void)layoutSubviews{
    [super layoutSubviews];
    self.imageView.bounds=CGRectMake(0,0,GCGIconPointSize,GCGIconPointSize);
}
@end
