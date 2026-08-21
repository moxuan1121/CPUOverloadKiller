#import "GCGTargetCell.h"
#import <Preferences/PSSpecifier.h>

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
    self.imageView.image=GCGResizeIcon([specifier propertyForKey:@"iconImage"]);
    self.detailTextLabel.text=[specifier propertyForKey:@"subtitle"];
}
- (void)layoutSubviews{
    [super layoutSubviews];
    self.imageView.bounds=CGRectMake(0,0,GCGIconPointSize,GCGIconPointSize);
}
@end
