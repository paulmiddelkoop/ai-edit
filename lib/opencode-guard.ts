// Loaded by the opencode server that bin/ai-edit-opencode starts. Runs right
// before each model request: only AI Edit's system prompt and the one user
// message may go out, without tools. Anything else throws, and a throw sends
// nothing. The result of each check goes to AI_EDIT_GUARD_STATUS, without
// the text; the bridge's probe is checked, then stopped here.
import { readFileSync, writeFileSync } from "node:fs"

const system = readFileSync(process.env.AI_EDIT_SYSTEM_FILE!, "utf8").trim()
const probe = process.env.AI_EDIT_PROBE!
const status = (result: object) => writeFileSync(process.env.AI_EDIT_GUARD_STATUS!, JSON.stringify(result))
const text = (parts: any[]) => parts.map((part) => part?.text ?? "").join("")

export default {
  id: "ai-edit.guard",
  setup: async (ctx: any) => {
    await ctx.session.hook("context", (event: any) => {
      const problem =
        event.agent !== "rewrite" ? "another agent"
        : Object.keys(event.tools).length ? "tools"
        : event.messages.length !== 1 || event.messages[0].role !== "user" ? "other messages"
        : text(event.system.slice(0, 1)) !== system ? "another system prompt"
        : ""
      status({ sessionID: event.sessionID, refused: problem || null })
      if (problem) throw new Error("AI Edit refused a request with " + problem)
      event.system = event.system.slice(0, 1)
      if (text(event.messages[0].content) === probe) throw new Error("AI Edit context check")
    })
  },
}
