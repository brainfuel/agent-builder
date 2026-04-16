import SwiftUI

enum AppConfiguration {
    enum Canvas {
        static let cardSize = CGSize(width: 264, height: 88)
        static let minimumSize = CGSize(width: 1900, height: 1200)
        static let minZoom: CGFloat = 0.3
        static let maxZoom: CGFloat = 1.5
        static let zoomStep: CGFloat = 0.1
        static let horizontalPadding: CGFloat = 240
        static let verticalPadding: CGFloat = 220
        static let anchorVerticalInset: CGFloat = 24
        static let layoutHorizontalInset: CGFloat = 16
    }

    enum Layout {
        static let topY: CGFloat = 132
        static let rowSpacing: CGFloat = 208
        static let siblingGap: CGFloat = 24
        static let rootGap: CGFloat = 40
    }

    enum Timing {
        static let liveStatusPollIntervalNanoseconds: UInt64 = 300_000_000
        static let copyIndicatorResetDelay: Duration = .seconds(1.5)
        static let scrollDelayWhenDrawerOpen: Duration = .milliseconds(50)
        static let scrollDelayWhenDrawerClosed: Duration = .milliseconds(350)
    }

    enum Motion {
        static let layoutSpringResponse: Double = 0.5
        static let layoutSpringDamping: Double = 0.82
    }

    enum MockCoordinator {
        static let responseDelayNanoseconds: UInt64 = 120_000_000
        static let confidence: Double = 0.82
    }
}

enum PromptTemplateConfig {
    static let generateStructureUserLeadIn = "Design a multi-agent team structure."
    static let generateStructureUserTaskQuestionHeading = "Task question:"
    static let generateStructureUserStrategyHeading = "Structure strategy:"
    static let generateStructureUserContextHeading = "Additional context:"
    static let generateStructureUserStrictResponseInstruction = "Respond with ONLY the JSON structure. No markdown code fences, no explanation."

    static let generateStructureLeadIn = """
    You are designing a multi-agent orchestration graph. The app supports these node types:
    - agent: An LLM-powered autonomous agent
    - human: A human review/approval gate
    - input: The entry point node (exactly one, always included automatically)
    - output: The exit point node (exactly one, always included automatically)
    """

    static let generateStructureRules = """
    - Do NOT include input or output nodes — the app adds those automatically
    - Create between 2-8 agent/human nodes depending on task complexity
    - The first node should be a coordinator or primary agent
    - Each non-root node must have exactly one parent link
    - Links go from parent (fromID) to child (toID)
    - Every node needs a unique UUID (use v4 format)
    - Position nodes in a logical hierarchy (x: 0-1000, y: 0-800)
    - Give each node a detailed roleDescription and outputSchemaDescription
    """

    static let generateStructureJSONContractTemplate = """
    Respond with ONLY valid JSON matching this exact schema (no markdown, no explanation):
    {
      "nodes": [
        {
          "id": "uuid-string",
          "name": "Agent Name",
          "title": "Role Title",
          "department": "Department",
          "type": "agent",
          "provider": "%@",
          "roleDescription": "Detailed description of what this agent does...",
          "outputSchema": "Schema Name",
          "outputSchemaDescription": "Detailed format description...",
          "securityAccess": ["workspaceRead"],
          "positionX": 400,
          "positionY": 0
        }
      ],
      "links": [
        {
          "fromID": "parent-uuid",
          "toID": "child-uuid",
          "tone": "blue"
        }
      ]
    }
    """

    static let structureChatLeadIn = """
    You are a structure copilot for a multi-agent graph editor.
    Your job is to either:
    1) reply conversationally, or
    2) return an updated structure snapshot to apply to the canvas.
    """

    static let structureChatResponseContract = """
    Return ONLY valid JSON in one of these forms:
    {"mode":"chat","message":"..."}
    {"mode":"update","message":"...","structure":{"nodes":[...],"links":[...]}}
    """

    static let structureChatNodeSchema = """
    Node schema (all fields required unless marked optional):
    {
      "id": "string (UUID or short ID)",
      "name": "string",
      "title": "string (short display label)",
      "department": "string (e.g. Analysis, Automation, Synthesis, Research)",
      "type": "agent",
      "provider": "string (one of the configured providers)",
      "roleDescription": "string (what this agent does)",
      "outputSchema": "string (optional, e.g. Task Result, LLM Analysis)",
      "outputSchemaDescription": "string (optional, describes the output)",
      "securityAccess": ["string"] (optional),
      "assignedTools": ["string"] (optional, tool IDs to enable on this node),
      "positionX": number (optional),
      "positionY": number (optional)
    }
    """

    static let structureChatLinkSchema = """
    Link schema:
    {"fromID": "string", "toID": "string", "tone": "string (optional: blue, teal, purple, green)"}
    """

    static let structureChatUpdateRules = """
    - Do NOT include input/output nodes; those are managed by the app.
    - Keep links valid and acyclic.
    - Only include links between the work nodes you define — links to/from input and output are added automatically.
    - Keep node IDs stable where possible when editing existing nodes.
    - Include a short message summarizing what changed.
    - If clarification is needed, use chat mode with a question.
    """

    static let structureChatTurnTemplate = """
    User request:
    %@

    Current canvas snapshot JSON (source of truth):
    %@
    """
}
