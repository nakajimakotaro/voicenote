import SwiftData
import SwiftUI

@main
struct VoiceNoteApp: App {
    let container: ModelContainer
    @State private var analysis: AnalysisService
    @State private var transcription: TranscriptionService

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Recording.self, Block.self, Segment.self, Cut.self, AppSettings.self)
        } catch {
            fatalError("ModelContainerを作れませんでした: \(error)")
        }
        self.container = container
        _analysis = State(initialValue: AnalysisService(context: container.mainContext))
        _transcription = State(initialValue: TranscriptionService(container: container))
        FileLayout.cleanTmp()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(analysis)
                .environment(transcription)
                .task {
                    analysis.resumeUnfinished()
                    await transcription.resumeInterrupted()
                }
        }
        .modelContainer(container)
    }
}
