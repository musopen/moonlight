// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-metadata

#import <iostream>
#import <vector>

#import <CoreGraphics/CGImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import <taglib/fileref.h>
#import <taglib/tag.h>

#import "StringUtil.h"
#import "TagPicture.h"
#import "TagPictureRef.h"

using namespace std;
using namespace TagLib;

// MARK: - TagLib string constants

static const auto pictureKey = String("PICTURE");
static const auto dataKey = String("data");
static const auto mimeTypeKey = String("mimeType");
static const auto descriptionKey = String("description");
static const auto pictureTypeKey = String("pictureType");
static const auto widthKey = String("width");
static const auto heightKey = String("height");
static const auto numColorsKey = String("numColors");
static const auto colorDepthKey = String("colorDepth");

static TagPictureRef *PictureRefFromProperties(const List<VariantMap> &pictures) {
    if (pictures.isEmpty())
        return nil;

    // take the first picture only
    auto picture = pictures.front();

    String pictureMimeType = picture.value(mimeTypeKey).value<String>();
    NSString *mimeType = StringUtil::utf8NSString(pictureMimeType);
    UTType *utType = [UTType typeWithMIMEType:mimeType];

    ByteVector pictureData = picture.value(dataKey).toByteVector();
    if (pictureData.isEmpty())
        return nil;

    NSData *nsData = [[NSData alloc] initWithBytes:pictureData.data() length:pictureData.size()];
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)nsData, NULL);

    if (!imageSource)
        return nil;

    if (!utType) {
        CFStringRef sourceType = CGImageSourceGetType(imageSource);
        if (sourceType) {
            utType = [UTType typeWithIdentifier:(__bridge NSString *)sourceType];
        }
    }

    if (!utType || ![utType conformsToType:UTTypeImage]) {
        CFRelease(imageSource);
        return nil;
    }

    CGImageRef imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
    CFRelease(imageSource);

    if (!imageRef)
        return nil;

    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);

    if (width == 0 || height == 0) {
        CGImageRelease(imageRef);
        return nil;
    }

    String pictureDescription = picture.value(descriptionKey).value<String>();
    String pictureType = picture.value(pictureTypeKey).value<String>();

    NSString *desc = StringUtil::utf8NSString(pictureDescription);
    NSString *pict = StringUtil::utf8NSString(pictureType);

    TagPictureRef *pictureRef = [[TagPictureRef alloc] initWithImage:imageRef
                                                              utType:utType
                                                  pictureDescription:desc
                                                         pictureType:pict];
    // TagPictureRef retains, so release the local +1 from CGImageCreate
    CGImageRelease(imageRef);

    return pictureRef;
}

static bool PropertiesFromPicture(TagPictureRef *picture, List<VariantMap> &properties) {
    properties.clear();

    if (!picture) {
        return true;
    }

    VariantMap map;

    if (picture.pictureDescription) {
        const char *value = StringUtil::utf8CString(picture.pictureDescription);
        map.insert(descriptionKey, String(value, String::Type::UTF8));
    }

    if (picture.pictureType) {
        const char *value = StringUtil::utf8CString(picture.pictureType);
        map.insert(pictureTypeKey, String(value, String::Type::UTF8));
    }

    NSString *mimeType = picture.utType.preferredMIMEType;
    const char *value = StringUtil::utf8CString(mimeType);
    map.insert(mimeTypeKey, String(value, String::Type::UTF8));

    const size_t width = CGImageGetWidth(picture.cgImage);
    const size_t height = CGImageGetHeight(picture.cgImage);
    const size_t bitsPerPixel = CGImageGetBitsPerPixel(picture.cgImage);
    map.insert(widthKey, int(width));
    map.insert(heightKey, int(height));
    map.insert(numColorsKey, 0);
    map.insert(colorDepthKey, int(bitsPerPixel));

    CFMutableDataRef mutableData = CFDataCreateMutable(NULL, 0);
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData(mutableData, (__bridge CFStringRef)picture.utType.identifier, 1, NULL);

    if (!destination) {
        CFRelease(mutableData);
        return false;
    }

    CGImageDestinationAddImage(destination, picture.cgImage, NULL);

    if (!CGImageDestinationFinalize(destination)) {
        CFRelease(destination);
        CFRelease(mutableData);
        return false;
    }

    NSData *nsData = (__bridge NSData *)mutableData;

    if (!nsData) {
        CFRelease(destination);
        CFRelease(mutableData);
        return false;
    }

    const char *bytes = (const char *)[nsData bytes];
    NSUInteger length = [nsData length];
    vector<char> vec(length);
    copy(bytes, bytes + length, vec.begin());

    ByteVector data = ByteVector(vec.data(), int(vec.size()));
    map.insert(dataKey, data);
    properties.append(map);

    CFRelease(destination);
    CFRelease(mutableData);

    return true;
}

@implementation TagPicture

- (nullable instancetype)initWithPicture:(nonnull TagPictureRef *)pictureRef {
    self = [super init];
    _pictureRef = pictureRef;
    return self;
}

// MARK: - Tag-based (core logic)

+ (nullable TagPictureRef *)readFromTag:(nonnull void *)opaqueTag {
    Tag *tag = static_cast<Tag *>(opaqueTag);
    return PictureRefFromProperties(tag->complexProperties(pictureKey));
}

+ (bool)write:(nullable TagPictureRef *)picture toTag:(nonnull void *)opaqueTag {
    Tag *tag = static_cast<Tag *>(opaqueTag);
    List<VariantMap> properties;
    if (!PropertiesFromPicture(picture, properties)) {
        return false;
    }
    return tag->setComplexProperties(pictureKey, properties);
}

// MARK: - Path-based (thin wrappers)

- (nullable instancetype)initWithPath:(nonnull NSString *)path {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        return NULL;
    }

    TagPictureRef *ref = PictureRefFromProperties(fileRef.complexProperties(pictureKey));
    if (ref) {
        self = [super init];
        _pictureRef = ref;
        return self;
    }

    Tag *tag = fileRef.tag();
    if (!tag)
        return NULL;

    ref = [TagPicture readFromTag:tag];
    if (!ref)
        return NULL;

    self = [super init];
    _pictureRef = ref;
    return self;
}

+ (bool)write:(nullable TagPictureRef *)picture path:(nonnull NSString *)path {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        return false;
    }

    List<VariantMap> properties;
    if (!PropertiesFromPicture(picture, properties)) {
        return false;
    }

    if (!fileRef.setComplexProperties(pictureKey, properties)) {
        return false;
    }

    return fileRef.save();
}

@end
