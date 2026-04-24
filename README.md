# Agent Builder

A SwiftUI agent-workflow canvas for designing, running, and inspecting multi-agent pipelines across ChatGPT, Claude, Gemini, and Grok — with a node-graph editor, live execution traces, MCP tool support, and local run notifications.

## Download

[![Latest release](https://img.shields.io/github/v/release/brainfuel/agent-builder?label=latest%20release&style=for-the-badge)](https://github.com/brainfuel/agent-builder/releases/latest)

**[⬇ Download the latest macOS build](https://github.com/brainfuel/agent-builder/releases/latest)** — signed, notarised `.dmg` for Apple Silicon.

After downloading, open the DMG and drag **Agent Builder** to your Applications folder.

## Overview

Agent Builder lets you:

- author agent workflows as a node graph (input → agents / humans → output)
- run the graph end-to-end against a live LLM provider, or simulate it offline
- step through execution with per-node traces, token counts, and run-from-here
- attach MCP tool servers (OAuth or API-key) and assign tools per agent node
- chat with a structure assistant that can mutate the graph for you
- get a local notification when a long-running task finishes

## Features

### Canvas & graph editing
- **Node-graph editor** — drag, link, zoom, search, undo/redo, orphan detection, cycle prevention
- **Built-in node templates** — Blank, Researcher, Planner, Router, Extractor, Synthesizer, Summariser, Fact Checker, Critic, Safety Gate, Human Review
- **User node templates** — save any node as a reusable template (SwiftData-backed); apply from the in-inspector **Templates** dropdown
- **User structure templates** — save entire graphs as reusable structures; reapply from the Structure Chat Templates menu
- **Persistent graph documents** — SwiftData-backed, auto-save on semantic mutation
- **Task list** with per-task Question, Context, and Structure Strategy fields

### Execution
- **Live coordinator orchestration** — reachable-node execution, pause on human nodes, approve/reject gates
- **Run-from-here** — re-execute any completed node without rerunning the full pipeline
- **Trace view** — per-node prompts, responses, token counts, tool calls, and durations
- **Simulated runs** for offline development without consuming API quota
- **Run completion notifications** — local notification posted when a run finishes (succeeded / finished with issues)
- **Usage tracking** — per-provider token counts persisted locally

### Providers & models
- **Four providers** — ChatGPT, Claude, Gemini, Grok
- **Per-provider API keys** stored in the macOS Keychain
- **Per-provider model selection** with cached model lists fetched on demand

### Tools & MCP
- **MCP integration** — add remote MCP servers (OAuth 2.1 with PKCE or static API keys) and surface their tools to agents
- **Curated MCP catalog** — GitHub, Notion, Linear, Slack, Stripe, Supabase, Exa Search, Cloudinary, Vercel, Airtable
- **Per-node tool assignment** — allow specific tools per agent, or enable global tool access
- **Security access model** — `workspaceRead`, `workspaceWrite`, `webAccess` permissions; workspace permissions auto-granted when an MCP tool is assigned
- **Tool execution engine** — regex-based `[TOOL_CALL: name({json})]` parsing with bracket-fallback

### Assistants & UX
- **Structure chat** — natural-language graph edits with a dedicated assistant inspector tab
- **Mac Catalyst support** — hover tooltips and larger viewport affordances
- **Templates dropdown** in Node Details mirroring Structure Chat's template menu

## Provider Support

| Provider | Chat | Model List | Tool Calling |
|---|---|---|---|
| ChatGPT | Yes | Yes | Yes |
| Claude | Yes | Yes | Yes |
| Gemini | Yes | Yes | Partial |
| Grok | Yes | Yes | Partial |

Live execution requires a valid API key plus a selected model per participating agent node.

## Requirements

- Xcode 17+
- iOS 18 / Mac Catalyst SDK supported by your local Xcode install
- Valid API key(s) for any provider you want to use

The current project settings in `Agentic.xcodeproj` target the latest SDK versions configured in the project file.

## Getting Started

1. Clone this repository.
2. Open [Agentic.xcodeproj](Agentic.xcodeproj) in Xcode.
3. Select the `Agentic` scheme.
4. Choose a run destination (an iPhone simulator or `My Mac (Mac Catalyst)`).
5. Build and run.

CLI build example:

```bash
xcodebuild -project Agentic.xcodeproj -scheme Agentic -configuration Debug build
```

### Building your own fork

The project ships with the original author's signing settings. If you're forking to build and ship your own copy, change these before you hit Run:

1. **Development team** — open the `Agentic` target in Xcode, go to **Signing & Capabilities**, and pick your own team. This rewrites `DEVELOPMENT_TEAM` throughout `Agentic.xcodeproj/project.pbxproj`.
2. **Bundle identifier** — in the same pane, change `PRODUCT_BUNDLE_IDENTIFIER` from `com.moosia.agentic` to something you own (e.g. `com.yourorg.agentbuilder`). There are ~7 occurrences across Debug/Release for the main target and test targets.
3. **OAuth URL scheme** — `Agentic/Info.plist` registers the `agentic://` URL scheme for MCP OAuth callbacks. If you're sharing a machine with another user's build, rename it to something namespaced (e.g. your bundle ID) and update any hardcoded references in `Agentic/Services/MCP`.
4. **APNs environment** — `Agentic/Agentic.entitlements` has `aps-environment = development`. Flip to `production` before distributing via TestFlight or the App Store.
5. **API keys are not bundled.** Every provider (ChatGPT, Claude, Gemini, Grok) and any credentialed MCP server expects you to paste a key into **Settings** at runtime — keys are stored in the macOS Keychain, never in the repo. There is no `.env` to create.

## Usage

1. Launch the app and open the default workflow, or create a new task from the sidebar.
2. Tap an empty canvas area and add agent or human nodes from the **+** menu; link them by dragging from a selected node's link handle.
3. Open the Inspector panel to edit a node's provider, model, role description, tools, and I/O schemas. Use the **Templates** dropdown to apply a built-in or saved template, or save the current node as a template.
4. Paste provider API keys in **Settings** (Keychain-backed) and pick a model per agent node.
5. Add MCP servers from **Settings → Tools** — pick from the curated catalog (OAuth or API-key) or paste a custom endpoint.
6. Press **Run** to execute the live coordinator. When the run finishes you'll get a local notification summarising pass/fail counts.
7. Use the Results drawer to step through the trace, view per-node prompts/responses, and run from any completed node.
8. Open the Structure chat tab to ask the assistant to add, remove, or rewire nodes in natural language.

## Data Storage

- API keys are stored securely in the macOS Keychain.
- Graph documents, user node templates, user structure templates, and MCP server connections are persisted locally with SwiftData.
- Provider/model preferences and usage counters are stored with `@AppStorage` / local files.
- No server-side app backend is included in this project.

## Testing

Unit tests cover the pure `CanvasLayoutEngine` (cycle detection, reachability, link normalization, default schemas) and the `CanvasViewportState` zoom-clamping helper.

```bash
xcodebuild -project Agentic.xcodeproj -scheme Agentic \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug test
```

## Project Structure

**Entry point**
- [Agentic/App/AgenticApp.swift](Agentic/App/AgenticApp.swift): App entry point, `ModelContainer` setup, notification authorisation, view-model wiring
- [Agentic/ContentView.swift](Agentic/ContentView.swift): Root layout — header, task list, canvas, inspector, results drawer

**App-wide configuration**
- [Agentic/App/AppTheme.swift](Agentic/App/AppTheme.swift): Color tokens (brand, surfaces, link tones)
- [Agentic/App/AppConfiguration.swift](Agentic/App/AppConfiguration.swift): Layout, motion, and canvas constants
- [Agentic/App/AppDependencies.swift](Agentic/App/AppDependencies.swift): Bundled services injected into view models

**Models (domain)**
- [Agentic/Models/Domain/GraphModels.swift](Agentic/Models/Domain/GraphModels.swift): `OrgNode`, `NodeLink`, `LinkTone`, `HierarchySnapshot`
- [Agentic/Models/Domain/ExecutionAndTemplateModels.swift](Agentic/Models/Domain/ExecutionAndTemplateModels.swift): Coordinator run, trace step, built-in templates
- [Agentic/Models/Domain/MCPToolModels.swift](Agentic/Models/Domain/MCPToolModels.swift): MCP tool definitions
- [Agentic/Models/Domain/StructureChatModels.swift](Agentic/Models/Domain/StructureChatModels.swift): Structure assistant request/response parsing
- [Agentic/Models/Domain/TemplateCatalogModels.swift](Agentic/Models/Domain/TemplateCatalogModels.swift): Default schemas, provider enum, preset roles, `NodeTemplate` catalog, curated MCP server list

**Models (persistence)**
- [Agentic/Models/Persistence/GraphDocument.swift](Agentic/Models/Persistence/GraphDocument.swift): SwiftData `@Model` for persisted graphs
- [Agentic/Models/Persistence/UserNodeTemplate.swift](Agentic/Models/Persistence/UserNodeTemplate.swift): User-saved node presets
- [Agentic/Models/Persistence/UserStructureTemplate.swift](Agentic/Models/Persistence/UserStructureTemplate.swift): User-saved graph structures
- [Agentic/Models/Persistence/MCPServerConnection.swift](Agentic/Models/Persistence/MCPServerConnection.swift): MCP server records

**Services**
- [Agentic/Services/Canvas/CanvasLayoutEngine.swift](Agentic/Services/Canvas/CanvasLayoutEngine.swift): Pure layout/graph math (Foundation + CoreGraphics only, fully unit-tested)
- [Agentic/Services/Execution/CoordinatorOrchestrator.swift](Agentic/Services/Execution/CoordinatorOrchestrator.swift): Live coordinator execution
- [Agentic/Services/Execution/LLMWorkflowServices.swift](Agentic/Services/Execution/LLMWorkflowServices.swift): Structure generation and node execution
- [Agentic/Services/Execution/LiveProviderExecutionService.swift](Agentic/Services/Execution/LiveProviderExecutionService.swift): Provider dispatch with tool-call loop
- [Agentic/Services/Execution/ToolExecutionEngine.swift](Agentic/Services/Execution/ToolExecutionEngine.swift): `[TOOL_CALL: ...]` parsing and dispatch to MCP
- [Agentic/Services/MCP](Agentic/Services/MCP): MCP client, manager, OAuth handler, stdio client, tool discovery
- [Agentic/Services/Persistence](Agentic/Services/Persistence): Keychain, usage tracking, document persistence
- [Agentic/Services/Providers](Agentic/Services/Providers): Per-provider API adapters (OpenAI, Anthropic, Gemini, Grok)
- [Agentic/Services/RunCompletionNotificationService.swift](Agentic/Services/RunCompletionNotificationService.swift): Local notification on run completion

**View models**
- [Agentic/ViewModels/CanvasViewModel.swift](Agentic/ViewModels/CanvasViewModel.swift): Graph state, mutations, persistence coordination
- [Agentic/ViewModels/CanvasViewportState.swift](Agentic/ViewModels/CanvasViewportState.swift): Transient viewport (zoom, search, scroll proxy)
- [Agentic/ViewModels/ExecutionViewModel.swift](Agentic/ViewModels/ExecutionViewModel.swift): Run lifecycle, trace state, run-from-here, notification posting
- [Agentic/ViewModels/StructureViewModel.swift](Agentic/ViewModels/StructureViewModel.swift): Structure-chat assistant
- [Agentic/ViewModels/NavigationCoordinator.swift](Agentic/ViewModels/NavigationCoordinator.swift): Sheet and modal routing

**Views**
- [Agentic/Views/HeaderBarView.swift](Agentic/Views/HeaderBarView.swift): Top bar — task title, run controls, settings
- [Agentic/Views/Canvas](Agentic/Views/Canvas): Chart canvas, zoom controls, schema controls, orchestration strip
- [Agentic/Views/Inspector](Agentic/Views/Inspector): Node detail + structure chat inspector, tool permission detail views
- [Agentic/Views/Results](Agentic/Views/Results): Execution trace drawer
- [Agentic/Views/TaskList](Agentic/Views/TaskList): Task list sidebar and row
- [Agentic/Views/Shared](Agentic/Views/Shared): Shared view helpers, model-to-color mappings

**Tests**
- [AgenticTests/CanvasLayoutEngineTests.swift](AgenticTests/CanvasLayoutEngineTests.swift): Cycle detection, reachability, link normalization, schemas
- [AgenticTests/CanvasViewportStateTests.swift](AgenticTests/CanvasViewportStateTests.swift): Zoom clamping and defaults

## Known Limitations

- UI streaming of assistant responses is not yet wired end-to-end for every provider.
- Attachment uploads to agent nodes are not yet supported; nodes exchange structured text payloads.
- MCP tool calling is wired for ChatGPT and Claude; Gemini and Grok tool calling is partial.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to report bugs, suggest features, and submit pull requests.

## License

[MIT](LICENSE)
