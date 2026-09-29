// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-metadata

#import <iomanip>
#import <iostream>
#import <stdio.h>
#import <vector>

#import <CoreGraphics/CGImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/CGImageDestination.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import <taglib/aifffile.h>
#import <taglib/fileref.h>
#import <taglib/flacfile.h>
#import <taglib/id3v2tag.h>
#import <taglib/mp4file.h>
#import <taglib/mpegfile.h>
#import <taglib/oggfile.h>
#import <taglib/oggflacfile.h>
#import <taglib/opusfile.h>
#import <taglib/privateframe.h>
#import <taglib/uniquefileidentifierframe.h>
#import <taglib/xiphcomment.h>
#import <taglib/mp4tag.h>
#import <taglib/mp4item.h>
#import <taglib/rifffile.h>
#import <taglib/tag.h>
#import <taglib/tfilestream.h>
#import <taglib/textidentificationframe.h>
#import <taglib/tpropertymap.h>
#import <taglib/vorbisfile.h>
#import <taglib/wavfile.h>

#import "ChapterMarker.h"
#import "TagFile.h"
#import "TagFileType.h"
#import "TagLibBridge.h"
#import "TagPictureRef.h"

#import "StringUtil.h"

using namespace std;
using namespace TagLib;

@implementation TagLibBridge

static const char *MoonlightUFIDOwner = "https://moonlight.app/track-id";
static const char *MoonlightXiphKey = "MOONLIGHT_TRACK_ID";
static const char *MoonlightMP4Key = "----:com.moonlight.app:trackid";

static NSString *MoonlightNSString(const ByteVector &bytes) {
    if (bytes.isEmpty()) return nil;
    NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *MoonlightTXXXValue(const ID3v2::UserTextIdentificationFrame *frame) {
    if (!frame) return nil;
    const auto fields = frame->fieldList();
    if (fields.size() < 2) return nil;
    auto value = fields.begin();
    ++value; // The first field is the TXXX description.
    return StringUtil::utf8NSString(*value);
}

+ (nullable NSDictionary *)getProperties:(NSString *)path {
    TagFile *tagFile = [[TagFile alloc] initWithPath:path];

    if (![tagFile load]) {
        return NULL;
    }

    return tagFile.dictionary;
}

+ (bool)setProperties:(NSString *)path dictionary:(NSDictionary *)dictionary {
    TagFile *tagFile = [[TagFile alloc] initWithPath:path];

    [tagFile setDictionary:dictionary];

    return [tagFile save];
}

+ (bool)updateProperties:(NSString *)path setting:(NSDictionary<NSString *, NSString *> *)setting removing:(NSArray<NSString *> *)removing {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull() || fileRef.file() == nullptr) {
        cout << "Unable to read path:" << path.UTF8String << endl;
        return false;
    }

    PropertyMap properties = fileRef.file()->properties();

    for (NSString *key in removing) {
        if (key.length == 0) {
            continue;
        }
        properties.erase(String(key.UTF8String, String::UTF8));
    }

    for (NSString *key in [setting allKeys]) {
        NSString *value = [setting objectForKey:key];
        if (key.length == 0 || value == nil) {
            continue;
        }
        properties.replace(
            String(key.UTF8String, String::UTF8),
            StringList(String(value.UTF8String, String::UTF8))
        );
    }

    fileRef.setProperties(properties);
    return fileRef.save();
}

+ (nullable NSString *)getTitle:(NSString *)path {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        cout << "fileRef.isNull. Unable to read path: " << path.UTF8String << endl;
        return NULL;
    }

    Tag *tag = fileRef.tag();

    if (!tag) {
        return NULL;
    }

    return StringUtil::utf8NSString(tag->title());
}

+ (bool)setTitle:(NSString *)path title:(NSString *)title {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        cout << "Unable to read path:" << path.UTF8String << endl;
        return false;
    }

    Tag *tag = fileRef.tag();

    if (!tag) {
        cout << "Unable to create tag" << endl;
        return false;
    }

    tag->setTitle(String(title.UTF8String, String::UTF8));

    return fileRef.save();
}

+ (nullable NSString *)getComment:(NSString *)path {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        cout << "Unable to read path:" << path.UTF8String << endl;
        return NULL;
    }

    Tag *tag = fileRef.tag();

    if (!tag) {
        cout << "Unable to create tag" << endl;
        return NULL;
    }

    return StringUtil::utf8NSString(tag->comment());
}

+ (bool)setComment:(NSString *)path comment:(NSString *)comment {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        cout << "Unable to read path:" << path.UTF8String << endl;
        return false;
    }

    Tag *tag = fileRef.tag();

    if (!tag) {
        cout << "Unable to create tag" << endl;
        return false;
    }

    tag->setComment(String(comment.UTF8String, String::UTF8));

    return fileRef.save();
}

+ (bool)removeAllTags:(NSString *)path {
    FileRef fileRef(path.UTF8String);

    if (fileRef.isNull()) {
        cout << "Unable to read path: " << path.UTF8String << endl;
        return false;
    }

    NSString *fileType = [TagFileType detectType:path];

    // implementation for strip() is specific to each type of file

    bool stripped = false;

    if ([fileType isEqualToString:kTagFileTypeWave]) {
        auto *f = dynamic_cast<RIFF::WAV::File *>(fileRef.file());
        if (f) {
            f->strip();
            stripped = true;
        }
    } else if ([fileType isEqualToString:kTagFileTypeM4a] || [fileType isEqualToString:kTagFileTypeMp4]) {
        auto *f = dynamic_cast<MP4::File *>(fileRef.file());
        if (f) {
            f->strip();
            stripped = true;
        }
    } else if ([fileType isEqualToString:kTagFileTypeMp3]) {
        auto *f = dynamic_cast<MPEG::File *>(fileRef.file());
        if (f) {
            f->strip();
            stripped = true;
        }
    } else if ([fileType isEqualToString:kTagFileTypeFlac]) {
        auto *f = dynamic_cast<FLAC::File *>(fileRef.file());
        if (f) {
            f->strip();
            stripped = true;
        }
    }

    if (!stripped) {
        cout << "Resetting property map for " << path.UTF8String << endl;
        fileRef.setProperties(PropertyMap());
    }

    return fileRef.save();
}

+ (bool)copyTagsFromPath:(NSString *)path toPath:(NSString *)toPath {
    FileRef input(path.UTF8String);

    if (input.isNull()) {
        cout << "Unable to read" << path.UTF8String << endl;
        return false;
    }

    PropertyMap tags = input.file()->properties();

    if (tags.isEmpty()) {
        return true;
    }

    if (![self removeAllTags:toPath]) {
        cout << "Failed to remove tags in" << toPath.UTF8String << endl;
        return false;
    }

    FileRef output(toPath.UTF8String);

    if (output.isNull()) {
        cout << "Unable to read path: " << toPath.UTF8String << endl;
        return false;
    }

    output.tag()->setProperties(tags);

    return output.save();
}

+ (nullable NSString *)moonlightTrackID:(NSString *)path {
    FileRef fileRef(path.UTF8String, true, AudioProperties::Fast);
    if (fileRef.isNull() || fileRef.file() == nullptr) return nil;

    if (auto *mpeg = dynamic_cast<MPEG::File *>(fileRef.file())) {
        auto *tag = mpeg->ID3v2Tag(false);
        if (!tag) return nil;
        auto *ufid = ID3v2::UniqueFileIdentifierFrame::findByOwner(tag, String(MoonlightUFIDOwner, String::UTF8));
        if (ufid) return MoonlightNSString(ufid->identifier());
        auto *txxx = ID3v2::UserTextIdentificationFrame::find(tag, String(MoonlightXiphKey, String::UTF8));
        return MoonlightTXXXValue(txxx);
    }

    Ogg::XiphComment *xiph = nullptr;
    if (auto *flac = dynamic_cast<FLAC::File *>(fileRef.file())) xiph = flac->xiphComment(false);
    if (auto *vorbis = dynamic_cast<Ogg::Vorbis::File *>(fileRef.file())) xiph = vorbis->tag();
    if (auto *opus = dynamic_cast<Ogg::Opus::File *>(fileRef.file())) xiph = opus->tag();
    if (xiph) {
        const auto values = xiph->fieldListMap()[MoonlightXiphKey];
        if (!values.isEmpty()) return StringUtil::utf8NSString(values.front());
    }

    if (auto *mp4 = dynamic_cast<MP4::File *>(fileRef.file())) {
        auto items = mp4->tag()->itemMap();
        auto it = items.find(MoonlightMP4Key);
        if (it != items.end()) {
            const auto values = it->second.toStringList();
            if (!values.isEmpty()) return StringUtil::utf8NSString(values.front());
        }
    }
    return nil;
}

+ (NSDictionary<NSString *, NSString *> *)moonlightTrackIDFrames:(NSString *)path {
    NSMutableDictionary<NSString *, NSString *> *values = [[NSMutableDictionary alloc] init];
    FileRef fileRef(path.UTF8String, true, AudioProperties::Fast);
    if (fileRef.isNull() || fileRef.file() == nullptr) return values;

    auto *mpeg = dynamic_cast<MPEG::File *>(fileRef.file());
    if (!mpeg) return values;
    auto *tag = mpeg->ID3v2Tag(false);
    if (!tag) return values;

    auto *ufid = ID3v2::UniqueFileIdentifierFrame::findByOwner(tag, String(MoonlightUFIDOwner, String::UTF8));
    if (ufid) {
        NSString *value = MoonlightNSString(ufid->identifier());
        if (value) values[@"UFID"] = value;
    }
    auto *txxx = ID3v2::UserTextIdentificationFrame::find(tag, String(MoonlightXiphKey, String::UTF8));
    NSString *txxxValue = MoonlightTXXXValue(txxx);
    if (txxxValue) values[@"TXXX"] = txxxValue;
    return values;
}

+ (bool)setMoonlightTrackID:(NSString *)trackID path:(NSString *)path {
    FileRef fileRef(path.UTF8String, true, AudioProperties::Fast);
    if (fileRef.isNull() || fileRef.file() == nullptr || trackID.length == 0) return false;
    String identifier(trackID.UTF8String, String::UTF8);

    if (auto *mpeg = dynamic_cast<MPEG::File *>(fileRef.file())) {
        auto *tag = mpeg->ID3v2Tag(true);
        auto *existingUFID = ID3v2::UniqueFileIdentifierFrame::findByOwner(tag, String(MoonlightUFIDOwner, String::UTF8));
        ByteVector bytes(trackID.UTF8String, (unsigned int)strlen(trackID.UTF8String));
        if (existingUFID) existingUFID->setIdentifier(bytes);
        else tag->addFrame(new ID3v2::UniqueFileIdentifierFrame(String(MoonlightUFIDOwner, String::UTF8), bytes));

        auto *existingTXXX = ID3v2::UserTextIdentificationFrame::find(tag, String(MoonlightXiphKey, String::UTF8));
        if (existingTXXX) existingTXXX->setText(identifier);
        else tag->addFrame(new ID3v2::UserTextIdentificationFrame(
            String(MoonlightXiphKey, String::UTF8), StringList(identifier), String::UTF8
        ));
        return mpeg->save();
    }

    Ogg::XiphComment *xiph = nullptr;
    if (auto *flac = dynamic_cast<FLAC::File *>(fileRef.file())) xiph = flac->xiphComment(true);
    if (auto *vorbis = dynamic_cast<Ogg::Vorbis::File *>(fileRef.file())) xiph = vorbis->tag();
    if (auto *opus = dynamic_cast<Ogg::Opus::File *>(fileRef.file())) xiph = opus->tag();
    if (xiph) {
        xiph->addField(MoonlightXiphKey, identifier, true);
        return fileRef.save();
    }

    if (auto *mp4 = dynamic_cast<MP4::File *>(fileRef.file())) {
        mp4->tag()->setItem(MoonlightMP4Key, MP4::Item(StringList(identifier)));
        return mp4->save();
    }
    return false;
}

@end
