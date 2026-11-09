import { z } from "zod";
import { bridgeTool, type Ctx } from "./common.js";

const status = z.enum(["open", "doing", "done"]);

/** Todo list of the Godot editor's "Todo" dock (stored in res://.godot_mcp/todo.json). */
export function registerTodoTools(ctx: Ctx): void {
  bridgeTool(
    ctx,
    "todo_list",
    "Lists the tasks of the project's todo list shown in the Godot editor (Todo dock). " +
      "Each task has an id, text and status: open, doing (in progress) or done.",
    {
      status: z
        .enum(["all", "active", "open", "doing", "done"])
        .default("all")
        .describe('Filter. "active" = open + doing.'),
    },
    { readOnly: true },
  );

  bridgeTool(
    ctx,
    "todo_add",
    "Adds one or several tasks to the project's todo list (shown live in the Godot editor).",
    {
      text: z.string().optional().describe("Text of a single task."),
      items: z.array(z.string()).optional().describe("Several tasks at once, kept in this order."),
      status: status.default("open").describe("Initial status."),
      position: z.enum(["top", "bottom"]).default("bottom"),
    },
  );

  bridgeTool(
    ctx,
    "todo_update",
    "Changes a task: its text, its status (set `doing` when you start working on it, `done` when finished) and/or its position.",
    {
      id: z.string().describe("Task id from todo_list or todo_add."),
      text: z.string().optional(),
      status: status.optional(),
      position: z
        .union([z.enum(["top", "bottom"]), z.number().int().min(0)])
        .optional()
        .describe('"top", "bottom" or a 0-based index in the list.'),
    },
  );

  bridgeTool(
    ctx,
    "todo_remove",
    "Deletes tasks from the todo list, by id or all the finished ones. The user can still undo the deletion in the dock.",
    {
      id: z.string().optional(),
      ids: z.array(z.string()).optional(),
      done_only: z.boolean().default(false).describe("Delete every task whose status is done."),
    },
    { destructive: true },
  );
}
