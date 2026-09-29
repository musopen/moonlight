// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-metadata

#import <Foundation/Foundation.h>

#import "TagPictureRef.h"

NS_ASSUME_NONNULL_BEGIN

/// Static utility class providing core TagLib operations for reading, writing,
/// copying, and stripping audio metadata tags across all TagLib-supported formats.
@interface TagLibBridge : NSObject

/// Reads all tags from the file as a dictionary keyed by TagLib property names.
/// @param path Absolute path to the audio file.
/// @return A mutable dictionary of tag properties, or `nil` if the file cannot be opened.
+ (nullable NSMutableDictionary *)getProperties:(NSString *)path;

/// Writes a dictionary of tag properties to the file, replacing existing tags.
/// @param path Absolute path to the audio file.
/// @param dictionary Tag properties keyed by TagLib property names.
/// @return `true` if the write succeeded.
+ (bool)setProperties:(NSString *)path dictionary:(NSDictionary *)dictionary;

/// Applies a sparse tag update without stripping or replacing the whole tag map.
/// @param path Absolute path to the audio file.
/// @param setting Tag properties to set, keyed by TagLib property names.
/// @param removing Tag property keys to remove.
/// @return `true` if the write succeeded.
+ (bool)updateProperties:(NSString *)path setting:(NSDictionary<NSString *, NSString *> *)setting removing:(NSArray<NSString *> *)removing;

/// Reads the title tag from the file.
/// @param path Absolute path to the audio file.
/// @return The title string, or `nil` if not present.
+ (nullable NSString *)getTitle:(NSString *)path;

/// Writes or updates the title tag in the file.
/// @param path Absolute path to the audio file.
/// @param comment The new title string.
/// @return `true` if the write succeeded.
+ (bool)setTitle:(NSString *)path title:(NSString *)comment;

/// Reads the comment tag from the file.
/// @param path Absolute path to the audio file.
/// @return The comment string, or `nil` if not present.
+ (nullable NSString *)getComment:(NSString *)path;

/// Writes or updates the comment tag in the file.
/// @param path Absolute path to the audio file.
/// @param comment The new comment string.
/// @return `true` if the write succeeded.
+ (bool)setComment:(NSString *)path comment:(NSString *)comment;

/// Strips all tags (ID3, APE, Xiph, etc.) from the file.
/// @param path Absolute path to the audio file.
/// @return `true` if the operation succeeded.
+ (bool)removeAllTags:(NSString *)path;

/// Copies all tags from one file to another, overwriting existing tags in the destination.
/// @param path Source file path to read tags from.
/// @param toPath Destination file path to write tags to.
/// @return `true` if the copy succeeded.
+ (bool)copyTagsFromPath:(NSString *)path toPath:(NSString *)toPath;

/// Reads Moonlight's portable logical-track identifier using the native tag
/// mechanism for MP3, FLAC/Ogg/Opus, or audio-only M4A.
+ (nullable NSString *)moonlightTrackID:(NSString *)path;

/// Returns the Moonlight MP3 identity values stored in the ID3v2 frames.
/// The dictionary uses `UFID` and `TXXX` keys and is empty for non-MP3 files.
+ (NSDictionary<NSString *, NSString *> *)moonlightTrackIDFrames:(NSString *)path;

/// Writes Moonlight's portable identifier without replacing unrelated tags.
+ (bool)setMoonlightTrackID:(NSString *)trackID path:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
