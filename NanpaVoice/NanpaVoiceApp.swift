import SwiftData
import SwiftUI

@main
struct NanpaVoiceApp: App {
    let container: ModelContainer
    @State private var analysis: AnalysisService

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Recording.self, Block.self, Segment.self, Cut.self, AppSettings.self)
        } catch {
            fatalError("ModelContainerを作れませんでした: \(error)")
        }
        self.container = container
        _analysis = State(initialValue: AnalysisService(context: container.mainContext))
        FileLayout.cleanTmp()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(analysis)
                .task { analysis.resumeUnfinished() }
        }
        .modelContainer(container)
    }
}
