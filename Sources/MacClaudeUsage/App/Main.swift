import Foundation

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--statusline") {
            // Headless mode: Claude Code runs us as its status-line command.
            StatusLineCommand.run()
            return
        }
        MacClaudeUsageApp.main()
    }
}
