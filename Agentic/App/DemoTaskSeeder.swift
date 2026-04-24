//
//  DemoTaskSeeder.swift
//  Agentic
//
//  DEBUG-only helper that seeds a set of realistic-looking tasks into the
//  SwiftData store when the app is launched with the `--seed-demo-tasks`
//  launch argument.
//
//  Intended use: populating the task list with camera-ready content before
//  taking marketing screenshots. Tasks are inserted with staggered
//  `updatedAt` timestamps (newest first) so they appear at the top of the
//  sidebar and push existing junk test tasks below the fold.
//
//  To activate: Product → Scheme → Edit Scheme… → Run → Arguments →
//  Arguments Passed On Launch → add `--seed-demo-tasks`. Run once, take
//  screenshot, remove the argument.
//
//  Seeding is guarded by a UserDefaults flag so re-running with the
//  argument does nothing unless the flag is cleared. To re-seed (e.g. after
//  deleting the demo tasks and wanting them back) also add
//  `--reset-demo-tasks-flag` which clears the guard before seeding.
//

#if DEBUG
import Foundation
import CoreGraphics
import SwiftData

enum DemoTaskSeeder {
    /// Call once during app startup. No-op unless `--seed-demo-tasks` is in
    /// the process arguments. Safe to call on every launch — seeding is
    /// guarded by a UserDefaults flag so the same data doesn't get inserted
    /// twice. Pass `--reset-demo-tasks-flag` alongside to force a re-seed.
    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--seed-demo-tasks") else { return }

        let alreadySeededKey = "AgentBuilder.demoTasksSeeded.v1"
        if args.contains("--reset-demo-tasks-flag") {
            UserDefaults.standard.removeObject(forKey: alreadySeededKey)
        }
        if UserDefaults.standard.bool(forKey: alreadySeededKey) {
            NSLog("[DemoTaskSeeder] Skipped — already seeded. Pass --reset-demo-tasks-flag to re-seed.")
            return
        }

        let now = Date()
        for (index, blueprint) in Self.blueprints.enumerated() {
            // Stagger timestamps one minute apart, newest first (blueprint index 0 wins).
            let timestamp = now.addingTimeInterval(-Double(index * 60))
            let snapshotData = try? JSONEncoder().encode(blueprint.snapshot)
            let document = GraphDocument(
                key: UUID().uuidString,
                title: blueprint.title,
                goal: blueprint.goal,
                context: blueprint.context,
                structureStrategy: blueprint.strategy,
                snapshotData: snapshotData ?? Data(),
                createdAt: timestamp,
                updatedAt: timestamp
            )
            context.insert(document)
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: alreadySeededKey)
            NSLog("[DemoTaskSeeder] Seeded %d demo tasks.", Self.blueprints.count)
        } catch {
            NSLog("[DemoTaskSeeder] Save failed: %@", String(describing: error))
        }
    }

    // MARK: - Demo data

    private struct Blueprint {
        let title: String
        let goal: String
        let context: String
        let strategy: String
        let snapshot: HierarchySnapshot
    }

    private static let blueprints: [Blueprint] = [
        Blueprint(
            title: "Weekly GitHub digest",
            goal: "Summarise this week's merged pull requests and open issues for the team Slack.",
            context: "Repo: moosia/agent-builder. Focus on user-visible changes, skip internal refactors. Audience is the product team, not engineers.",
            strategy: "Fetch merged PRs and open issues via GitHub MCP, filter to user-visible changes, summarise into a Slack-ready digest.",
            snapshot: makeChainSnapshot(agentName: "Digest Writer", agentTitle: "Summariser", provider: .chatGPT)
        ),
        Blueprint(
            title: "Competitor pricing research",
            goal: "Compile a table of pricing tiers for LangGraph, Flowise, n8n, and Dify for Q2 planning.",
            context: "Plans, per-seat vs flat fees, included run counts, and any free tiers. Cite source URLs for each.",
            strategy: "Parallel research on each competitor's pricing page via web search, synthesise into one comparison table.",
            snapshot: makeParallelSnapshot(branchNames: ["LangGraph", "Flowise", "n8n", "Dify"], provider: .claude)
        ),
        Blueprint(
            title: "v1.4 release notes",
            goal: "Draft user-facing release notes for v1.4 from the commit history since v1.3.",
            context: "Tone: practical, concise. Group into Added / Improved / Fixed. No marketing fluff.",
            strategy: "Read commit log, classify each commit, draft notes in the three standard categories.",
            snapshot: makeChainSnapshot(agentName: "Release Notes Drafter", agentTitle: "Technical Writer", provider: .claude)
        ),
        Blueprint(
            title: "Support ticket triage",
            goal: "Classify incoming support tickets by severity and route to the right team.",
            context: "Categories: bug, billing, feature-request, question. Severity: critical, high, medium, low. Route bugs to engineering, billing to finance, the rest to customer success.",
            strategy: "Classify each ticket, then route using a conditional edge based on the classification output.",
            snapshot: makeRouterSnapshot(provider: .chatGPT)
        ),
        Blueprint(
            title: "Feature launch copy",
            goal: "Write a launch blog post and three announcement tweets for the new Critic node.",
            context: "Blog: 400-600 words, developer audience. Tweets: one technical, one benefit-led, one playful.",
            strategy: "Generate blog post, then generate tweets conditioned on the blog's key points.",
            snapshot: makeChainSnapshot(agentName: "Marketing Writer", agentTitle: "Copywriter", provider: .gemini)
        ),
        Blueprint(
            title: "PR regression review",
            goal: "Review the five most recent open PRs and flag any that could introduce regressions.",
            context: "Focus on: missing tests, API surface changes, performance-sensitive code paths. Output a short memo per PR.",
            strategy: "For each PR: fetch diff via GitHub MCP, critic agent scores on rubric, synthesise flagged ones into a digest.",
            snapshot: makeCriticSnapshot(provider: .claude)
        ),
        Blueprint(
            title: "Team weekly digest",
            goal: "Compile a weekly update covering shipped work, blockers, and next week's priorities.",
            context: "Source: Linear for issues, GitHub for PRs, Slack for blockers. Format as a single markdown brief.",
            strategy: "Three parallel research branches (Linear, GitHub, Slack), synthesise into a digest, human review before sending.",
            snapshot: makeSynthesisSnapshot(provider: .chatGPT)
        )
    ]

    // MARK: - Snapshot builders

    /// Input → Agent → Output linear chain.
    private static func makeChainSnapshot(
        agentName: String,
        agentTitle: String,
        provider: LLMProvider
    ) -> HierarchySnapshot {
        let inputID = UUID()
        let agentID = UUID()
        let outputID = UUID()
        return HierarchySnapshot(
            nodes: [
                snapshotNode(id: inputID, name: "Input", title: "Entry Point", department: "System",
                             type: .input, provider: .chatGPT,
                             role: "Fixed start node for task inputs.",
                             output: DefaultSchema.goalBrief,
                             x: 950, y: 176),
                snapshotNode(id: agentID, name: agentName, title: agentTitle, department: "Automation",
                             type: .agent, provider: provider,
                             role: "Handles the task end-to-end.",
                             output: DefaultSchema.taskResult,
                             x: 950, y: 380),
                snapshotNode(id: outputID, name: "Output", title: "Final Result", department: "System",
                             type: .output, provider: .chatGPT,
                             role: "Fixed end node for final outputs.",
                             output: DefaultSchema.taskResult,
                             x: 950, y: 600)
            ],
            links: [
                HierarchySnapshotLink(fromID: inputID, toID: agentID, tone: .blue),
                HierarchySnapshotLink(fromID: agentID, toID: outputID, tone: .teal)
            ]
        )
    }

    /// Input → N parallel branches → Synthesizer → Output.
    private static func makeParallelSnapshot(branchNames: [String], provider: LLMProvider) -> HierarchySnapshot {
        let inputID = UUID()
        let synthID = UUID()
        let outputID = UUID()
        let branchIDs = branchNames.map { _ in UUID() }

        var nodes: [HierarchySnapshotNode] = []
        nodes.append(snapshotNode(id: inputID, name: "Input", title: "Entry Point", department: "System",
                                   type: .input, provider: .chatGPT, role: "Fixed start node for task inputs.",
                                   output: DefaultSchema.goalBrief, x: 950, y: 176))
        for (index, name) in branchNames.enumerated() {
            let spread: CGFloat = 220
            let x = 950 + CGFloat(index - (branchNames.count - 1)) * spread / CGFloat(branchNames.count) * 2
            nodes.append(snapshotNode(id: branchIDs[index], name: name, title: "Researcher", department: "Discovery",
                                       type: .agent, provider: provider,
                                       role: "Researches \(name) and drafts a brief.",
                                       output: DefaultSchema.researchBrief,
                                       x: Double(x), y: 380))
        }
        nodes.append(snapshotNode(id: synthID, name: "Synthesizer", title: "Integrator", department: "Synthesis",
                                   type: .agent, provider: provider,
                                   role: "Merges branch outputs into a single comparison.",
                                   output: DefaultSchema.taskResult, x: 950, y: 600))
        nodes.append(snapshotNode(id: outputID, name: "Output", title: "Final Result", department: "System",
                                   type: .output, provider: .chatGPT, role: "Fixed end node for final outputs.",
                                   output: DefaultSchema.taskResult, x: 950, y: 800))

        var links: [HierarchySnapshotLink] = []
        for branchID in branchIDs {
            links.append(HierarchySnapshotLink(fromID: inputID, toID: branchID, tone: .blue))
            links.append(HierarchySnapshotLink(fromID: branchID, toID: synthID, tone: .orange))
        }
        links.append(HierarchySnapshotLink(fromID: synthID, toID: outputID, tone: .teal))
        return HierarchySnapshot(nodes: nodes, links: links)
    }

    /// Input → Router → Output (routes implicit by the router's output).
    private static func makeRouterSnapshot(provider: LLMProvider) -> HierarchySnapshot {
        let inputID = UUID()
        let routerID = UUID()
        let outputID = UUID()
        return HierarchySnapshot(
            nodes: [
                snapshotNode(id: inputID, name: "Input", title: "Entry Point", department: "System",
                             type: .input, provider: .chatGPT, role: "Fixed start node for task inputs.",
                             output: DefaultSchema.goalBrief, x: 950, y: 176),
                snapshotNode(id: routerID, name: "Ticket Router", title: "Classifier", department: "Control Plane",
                             type: .agent, provider: provider,
                             role: "Classifies ticket severity and category, picks the downstream team.",
                             output: DefaultSchema.taskResult, x: 950, y: 380),
                snapshotNode(id: outputID, name: "Output", title: "Final Result", department: "System",
                             type: .output, provider: .chatGPT, role: "Fixed end node for final outputs.",
                             output: DefaultSchema.taskResult, x: 950, y: 600)
            ],
            links: [
                HierarchySnapshotLink(fromID: inputID, toID: routerID, tone: .blue),
                HierarchySnapshotLink(fromID: routerID, toID: outputID, tone: .teal)
            ]
        )
    }

    /// Input → Fetcher → Critic → Summariser → Output.
    private static func makeCriticSnapshot(provider: LLMProvider) -> HierarchySnapshot {
        let inputID = UUID()
        let fetcherID = UUID()
        let criticID = UUID()
        let summariserID = UUID()
        let outputID = UUID()
        return HierarchySnapshot(
            nodes: [
                snapshotNode(id: inputID, name: "Input", title: "Entry Point", department: "System",
                             type: .input, provider: .chatGPT, role: "Fixed start node for task inputs.",
                             output: DefaultSchema.goalBrief, x: 950, y: 176),
                snapshotNode(id: fetcherID, name: "PR Fetcher", title: "Investigator", department: "Discovery",
                             type: .agent, provider: provider,
                             role: "Fetches open PR diffs and metadata.",
                             output: DefaultSchema.researchBrief, x: 950, y: 360),
                snapshotNode(id: criticID, name: "Critic", title: "Reviewer", department: "Quality",
                             type: .agent, provider: provider,
                             role: "Scores each PR on accuracy, completeness, and regression risk.",
                             output: DefaultSchema.validationReport, x: 950, y: 540),
                snapshotNode(id: summariserID, name: "Digest Writer", title: "Condenser", department: "Synthesis",
                             type: .agent, provider: .chatGPT,
                             role: "Condenses flagged PRs into a digest memo.",
                             output: DefaultSchema.taskResult, x: 950, y: 720),
                snapshotNode(id: outputID, name: "Output", title: "Final Result", department: "System",
                             type: .output, provider: .chatGPT, role: "Fixed end node for final outputs.",
                             output: DefaultSchema.taskResult, x: 950, y: 900)
            ],
            links: [
                HierarchySnapshotLink(fromID: inputID, toID: fetcherID, tone: .blue),
                HierarchySnapshotLink(fromID: fetcherID, toID: criticID, tone: .blue),
                HierarchySnapshotLink(fromID: criticID, toID: summariserID, tone: .orange),
                HierarchySnapshotLink(fromID: summariserID, toID: outputID, tone: .teal)
            ]
        )
    }

    /// Input → 3 sources → Synthesizer → Human Review → Output.
    private static func makeSynthesisSnapshot(provider: LLMProvider) -> HierarchySnapshot {
        let inputID = UUID()
        let linearID = UUID()
        let githubID = UUID()
        let slackID = UUID()
        let synthID = UUID()
        let humanID = UUID()
        let outputID = UUID()
        return HierarchySnapshot(
            nodes: [
                snapshotNode(id: inputID, name: "Input", title: "Entry Point", department: "System",
                             type: .input, provider: .chatGPT, role: "Fixed start node for task inputs.",
                             output: DefaultSchema.goalBrief, x: 950, y: 176),
                snapshotNode(id: linearID, name: "Linear", title: "Investigator", department: "Discovery",
                             type: .agent, provider: provider, role: "Pulls shipped issues from Linear.",
                             output: DefaultSchema.researchBrief, x: 700, y: 380),
                snapshotNode(id: githubID, name: "GitHub", title: "Investigator", department: "Discovery",
                             type: .agent, provider: provider, role: "Pulls merged PRs from GitHub.",
                             output: DefaultSchema.researchBrief, x: 950, y: 380),
                snapshotNode(id: slackID, name: "Slack", title: "Investigator", department: "Discovery",
                             type: .agent, provider: provider, role: "Scans Slack for blockers and wins.",
                             output: DefaultSchema.researchBrief, x: 1200, y: 380),
                snapshotNode(id: synthID, name: "Synthesizer", title: "Integrator", department: "Synthesis",
                             type: .agent, provider: provider,
                             role: "Merges all three sources into a single weekly digest.",
                             output: DefaultSchema.taskResult, x: 950, y: 580),
                snapshotNode(id: humanID, name: "Human Review", title: "Approval Gate", department: "Operations",
                             type: .human, provider: .chatGPT,
                             role: "Editor-in-chief approval before sending.",
                             output: DefaultSchema.releaseDecision, x: 950, y: 760),
                snapshotNode(id: outputID, name: "Output", title: "Final Result", department: "System",
                             type: .output, provider: .chatGPT, role: "Fixed end node for final outputs.",
                             output: DefaultSchema.taskResult, x: 950, y: 940)
            ],
            links: [
                HierarchySnapshotLink(fromID: inputID, toID: linearID, tone: .blue),
                HierarchySnapshotLink(fromID: inputID, toID: githubID, tone: .blue),
                HierarchySnapshotLink(fromID: inputID, toID: slackID, tone: .blue),
                HierarchySnapshotLink(fromID: linearID, toID: synthID, tone: .orange),
                HierarchySnapshotLink(fromID: githubID, toID: synthID, tone: .orange),
                HierarchySnapshotLink(fromID: slackID, toID: synthID, tone: .orange),
                HierarchySnapshotLink(fromID: synthID, toID: humanID, tone: .teal),
                HierarchySnapshotLink(fromID: humanID, toID: outputID, tone: .teal)
            ]
        )
    }

    private static func snapshotNode(
        id: UUID,
        name: String,
        title: String,
        department: String,
        type: NodeType,
        provider: LLMProvider,
        role: String,
        output: String,
        x: Double,
        y: Double
    ) -> HierarchySnapshotNode {
        HierarchySnapshotNode(
            id: id,
            name: name,
            title: title,
            department: department,
            type: type,
            provider: provider,
            roleDescription: role,
            inputSchema: DefaultSchema.goalBrief,
            outputSchema: output,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: output),
            selectedRoles: [],
            securityAccess: [],
            assignedTools: [],
            positionX: CGFloat(x),
            positionY: CGFloat(y)
        )
    }
}
#endif
