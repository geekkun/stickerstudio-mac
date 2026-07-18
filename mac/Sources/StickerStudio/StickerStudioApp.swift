#if os(macOS)
import SwiftUI

@main
struct StickerStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1024, minHeight: 660)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть видео…") {
                    if model.screen == .editor {
                        model.backToLanding()
                    }
                    model.pickFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.backMain.ignoresSafeArea()
            switch model.screen {
            case .landing:
                LandingView()
            case .loading:
                LoadingView()
            case .editor:
                if let editor = model.editor {
                    EditorScreen(model: editor)
                        .id(ObjectIdentifier(editor))
                }
            }
        }
        .alert("Не получилось", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct LoadingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView(value: Double(model.loadPercent), total: 100)
                .progressViewStyle(.linear)
                .frame(width: 320)
                .tint(Theme.accent)
            Text(model.loadText)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
        }
    }
}
#else
@main
struct StickerStudioApp {
    static func main() {
        print("StickerStudio UI доступен только на macOS; используйте stickerctl")
    }
}
#endif
