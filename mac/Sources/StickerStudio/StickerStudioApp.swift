#if os(macOS)
import SwiftUI

@main
struct StickerStudioApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Sticker Studio — UI в разработке")
                .frame(minWidth: 640, minHeight: 400)
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
