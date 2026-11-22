//
//  MulgRuntimeBoot.m
//  Starts the Mulg runtime when the game loads it, before the game's own code runs.
//
//  Upstream started MulgKit from a constructor in MulgLoader.m that did all start-up work
//  at once. Here the constructor only hands over to the runtime, which runs the minimal
//  "prepare" phase now and defers the rest until the first scene is active (PLAN.md §16.2 E5).
//

#import <Foundation/Foundation.h>

/// Implemented in Swift (MulgRuntime.swift) with @_cdecl.
extern void mulg_runtime_start(void);
extern void mulg_engine_prepare_game_callers(void);

__attribute__((constructor))
static void mulg_runtime_boot(void) {
    mulg_engine_prepare_game_callers();
    mulg_runtime_start();
}
