// Connection instructions match the app's distribution and isolated local profile.

import Foundation

enum OnboardingPasteString {
    static var current: String {
        BuildPolicy.isOfficialDistribution ? official : local
    }

    static var local: String {
        """
        Connect this local Design Canvas build to this project:

        1. Locate the design-canvas-app source checkout used to build the app. Ask me for its path if needed. In its mcp-server directory, run npm ci and npm run build.

        2. Configure this agent's MCP client to run node with the absolute path to that checkout's mcp-server/dist/index.js. Set these environment values on the MCP entry:
           DESIGN_CANVAS_PROFILE=local
           DESIGN_CANVAS_URL=\(BuildPolicy.localAPIURL)
           Use the source adapter; the older published npm package uses the official app's token profile. Keep the existing design-canvas MCP entry only if it already matches this local setup. Do not copy or commit authentication tokens.

        3. Start this project's dev server using its package.json command. Ask me if the command or project path is unclear. Restart the agent session after changing MCP configuration, then ask the MCP to show what's on my Design Canvas.

        Setup reference: https://github.com/charlieellington/design-canvas-app/blob/main/docs/MCP.md
        """
    }

    static let official = """
    Set up Design Canvas for this project. Do these steps in order:

    1. Install the MCP server. Run:
       claude mcp add design-canvas -s user -- npx -y design-canvas-mcp

    2. Start the dev server. Check package.json for the dev command (usually npm run dev, pnpm dev, etc). If you're not sure which command to use, ask me — never guess. Start it so it keeps running.

    3. After both succeed, tell me:
       "Done! MCP installed and dev server running.
       To finish setup, close this session and reopen.
       Then paste this as your first message:"

       And give me this exact prompt to copy:
       Show me what's on my Design Canvas

    If the install command errors (e.g. on Cursor or another agent), use the fallback:
    - Cursor: add {"design-canvas":{"command":"npx","args":["-y","design-canvas-mcp"]}} to .cursor/mcp.json
    - Other agents: run `npx -y design-canvas-mcp install`

    Edge cases (no package.json, port conflict, missing node) — ask me, never guess.
    """
}
