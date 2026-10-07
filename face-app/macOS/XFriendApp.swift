import SwiftUI

@main
struct XFriendApp: App {
    private let controller: FaceController

    init() {
        Log.installCrashLogging()
        let port = UInt16(ProcessInfo.processInfo.environment["XFRIEND_FACE_PORT"] ?? "") ?? 7777
        controller = FaceController(port: port)
        // Start here, not in onAppear: the link and audio must run even if macOS
        // relaunches the app without restoring its window.
        controller.start()
        Log.app.notice("XFriend face started (\(BuildInfo.platform), port \(port), log \(Log.fileURL.path))")
    }

    var body: some Scene {
        Window("XFriend", id: "face") {
            FaceView(controller: controller)
                .frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 1024, height: 768)  // iPad-ish 4:3
        .windowStyle(.hiddenTitleBar)
    }
}
