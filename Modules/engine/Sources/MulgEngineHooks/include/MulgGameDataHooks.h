#import <Foundation/Foundation.h>
#include <stdbool.h>
/// Set once after sandbox initialization, before the game's download SDK starts.
bool mulg_engine_set_game_data_root(const char * _Nonnull path);
/// Real data-volume path for a game capacity probe; unchanged outside owned roots.
const char * _Nullable mulg_engine_storage_capacity_path(const char * _Nullable path);
/// Whether both file URLs are on one volume (NO when either cannot be read).
BOOL mulg_engine_same_volume(NSURL * _Nullable first, NSURL * _Nonnull second);
/// Removes empty `.mulg-replacement-*` folders older than ten minutes from `parent`.
void mulg_engine_remove_stale_replacements(NSFileManager * _Nonnull files, NSURL * _Nonnull parent);
/// Where a replacement folder goes when macOS's own is on another volume: the first of `candidates` (container
/// folders) on `parent`'s volume, else `parent`.
NSURL * _Nonnull mulg_engine_replacement_base(NSURL * _Nonnull parent, NSArray<NSURL *> * _Nullable candidates);
