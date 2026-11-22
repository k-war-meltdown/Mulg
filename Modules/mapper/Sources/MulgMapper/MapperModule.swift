import Foundation
import MulgContracts
import MulgEngine

/// The control mapper (PLAN.md §16.12): the overlay where a player draws joysticks and skill
/// buttons on the game and binds them to keys, in the way of an emulator's key mapper.
///
/// It supplies the editor the controls module opens for ⌘K (`ModuleContext.controlEditor`); the
/// controls module keeps everything that touches input and files. Without this module, controls
/// falls back to its built-in editor.
@MainActor
public final class MapperModule: GameModule {
    public let id = ModuleID.mapper
    public var prerequisites: [ModuleID] { [.engine, .controls] }
    private var subscription: EventSubscription?
    #if canImport(UIKit) && !os(watchOS)
    private var editor: MapperEditor?
    #endif

    public init() {}

    public func prepare(_ context: ModuleContext) throws {}

    public func activate(_ context: ModuleContext) {
        #if canImport(UIKit) && !os(watchOS)
        let editor = MapperEditor(settings: context.settings.mulg.mapper)
        self.editor = editor
        context.controlEditor = editor
        subscription = context.events.subscribe(SettingsChanged.self) { [weak editor] change in
            editor?.apply(settings: change.new.mulg.mapper)
        }
        context.logger(for: id).info("Control mapper ready")
        #endif
    }
}
