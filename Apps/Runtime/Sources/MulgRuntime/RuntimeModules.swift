import MulgControls
import MulgDiagnostics
import MulgDisplay
import MulgEngine
import MulgGraphics
import MulgIdentity
import MulgIntegrations
import MulgMapper
import MulgCamera

/// The game-side modules that make up the runtime. Add a module here once it exists; the
/// module host sorts them into the start order (PLAN.md §1.5 rule 5).
@MainActor
enum RuntimeModules {
    static func all() -> [any GameModule] {
        [
            EngineCoreModule(),
            IdentityGameModule(),
            DisplayModule(),
            GraphicsModule(),
            ControlsModule(),
            MapperModule(),
            CameraModule(),
            DiagnosticsModule(),
            IntegrationsModule()
        ]
    }
}
