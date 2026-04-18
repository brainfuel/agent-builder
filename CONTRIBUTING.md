# Contributing to Agentic

Thanks for your interest in contributing to Agentic! This document explains how to get involved.

## Getting Started

1. Fork and clone the repository.
2. Open `Agentic.xcodeproj` in Xcode 17 or later.
3. Select the **Agentic** scheme and a run destination (for example an iPhone simulator or Mac Catalyst).
4. Build and run to make sure everything works before you make changes.

You will need a valid API key for at least one provider (ChatGPT, Claude, Gemini, or Grok) to execute agent workflows end to end. The app can be explored without keys — graph authoring works offline.

## How to Contribute

### Reporting Bugs

Open an issue and include:

- A clear description of the problem.
- Steps to reproduce it.
- What you expected to happen versus what actually happened.
- Your iOS/macOS version and Xcode version.

### Suggesting Features

Open an issue with the **enhancement** label. Describe the feature, why it would be useful, and any ideas you have for how it could work.

### Submitting Code

1. Create a branch from `main` for your work. Use a descriptive name like `fix/layout-cycle-bug` or `feature/mcp-tool-auth`.
2. Make your changes in small, focused commits.
3. Run the test suite and make sure it passes.
4. Open a pull request against `main`.

## Code Style

- Follow standard Swift conventions and the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Respect the project's MVVM layering. Models must not import SwiftUI. Services own domain logic. ViewModels orchestrate. Views render.
- Pure logic belongs in `Services/` as enums of static functions (see `CanvasLayoutEngine`) so it stays testable without SwiftUI.
- Keep files focused. If a file is growing past ~500 lines, consider splitting it.
- Use `async`/`await` for asynchronous work rather than callbacks.
- Prefer `@Observable` for view models and `@Bindable` at the view boundary over `@ObservedObject` / `@StateObject`.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) style where it makes sense:

```
feat: add run-from-here control for agent nodes
fix: prevent cycle when redirecting an anchor link
docs: document CanvasLayoutEngine public surface
chore: bump deployment target to iOS 18
```

A short summary on the first line is the most important part. Add a body if the change needs more context.

## Pull Request Guidelines

- Keep pull requests focused on a single change.
- Describe what the PR does and why.
- Reference any related issues (for example `Closes #12`).
- Make sure the project builds without warnings and tests pass before submitting.

## Testing

Unit tests live in `AgenticTests/`. The pure `CanvasLayoutEngine` is covered by `CanvasLayoutEngineTests.swift`; add tests alongside any new logic extracted into `Services/`.

Run the suite:

```bash
xcodebuild -project Agentic.xcodeproj -scheme Agentic \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug test
```

## Project Structure

```
Agentic/
├── App/                Entry point, theme, configuration, dependency container
├── Models/
│   ├── Domain/         Framework-agnostic domain types (Foundation + CoreGraphics only)
│   └── Persistence/    SwiftData @Model classes
├── Services/
│   ├── Canvas/         Pure layout/graph math (CanvasLayoutEngine)
│   ├── Execution/      Coordinator, workflow, and LLM execution
│   ├── MCP/            MCP tool discovery and invocation
│   ├── Persistence/    Keychain, model preferences, graph document wiring
│   └── Providers/      Provider-specific adapters
├── ViewModels/         @Observable orchestrators (Canvas, Execution, Structure, Navigation)
└── Views/              SwiftUI view components
    ├── Canvas/         Chart, zoom, schema controls
    ├── Inspector/      Node detail and structure chat panels
    ├── Results/        Execution trace drawer
    ├── TaskList/       Task list sidebar
    └── Shared/         Reusable view helpers
```

## Areas Where Help Is Welcome

Check the open issues for things to work on. Some areas that could use contributions:

- Additional provider adapters and streaming support.
- Expanded unit-test coverage (graph mutations, persistence round-trips).
- Accessibility improvements.
- Documentation and sample workflows.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
