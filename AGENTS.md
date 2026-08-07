# Repository Guidelines

## Project Structure & Module Organization
`Sources/MacCleanerCore/` holds shared models, protocols, services, cleanup modules, and `Resources/CleaningRules.json`. Keep scan and delete logic here. `Sources/MacCleanerCLI/` contains the `ArgumentParser` entry point, subcommands, and TUI helpers. `Sources/MacCleanerApp/` contains the SwiftUI app split into `App/`, `Features/`, `Components/`, and `Extensions/`. Tests live under `Tests/MacCleanerTests/` and are grouped by concern (`Models/`, `Modules/`, `Services/`, `ViewModels/`, `Mocks/`). `project.yml` is the source for the Xcode app project; `MacCleaner.xcodeproj/` is generated output.

## Build, Test, and Development Commands
Use `swift build` to compile the package targets. Use `swift run mac-cleaner` for the interactive CLI, `swift run mac-cleaner scan --json` for machine-readable scan output, and `swift run mac-cleaner clean --dry-run --all --yes` to preview deletions safely. Run `swift test` to execute the Swift Testing suites. When `project.yml` changes, regenerate the app project with `xcodegen generate`, then open `MacCleaner.xcodeproj` in Xcode to run the macOS app.

## Coding Style & Naming Conventions
Follow the existing Swift style: 4-space indentation, small focused types, and one primary type per file. Use `PascalCase` for types and `lowerCamelCase` for methods, properties, and test helpers. Keep shared behavior in `MacCleanerCore` instead of duplicating logic in the CLI or app. Prefer immutable `struct` models with `Sendable` where appropriate; SwiftUI view models currently use `@Observable` and `@MainActor`. Keep user-facing UI strings in Simplified Chinese to match the app.

## Testing Guidelines
Tests use Swift Testing, not XCTest: `import Testing`, `@Suite`, `@Test`, and `#expect`. Name files with the `*Tests.swift` suffix and place them beside the matching concern, for example `Tests/MacCleanerTests/Modules/IOSSimulatorsModuleTests.swift`. Prefer deterministic tests with `MockShellExecutor` over real shell commands. Add tests for new cleanup rules, parser behavior, and selection or risk-level logic before changing deletion flows.

## Commit & Pull Request Guidelines
This checkout does not include local Git history, so use concise imperative commit subjects, ideally scoped when useful, such as `Core: tighten simulator filtering` or `App: confirm destructive selections`. Pull requests should summarize behavior changes, list the commands run, and call out any filesystem-risk or entitlement changes explicitly. Include screenshots for SwiftUI changes and mention `--dry-run` results when altering cleanup behavior.
