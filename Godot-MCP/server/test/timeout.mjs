// Checks that run_and_capture kills a game that never quits (and its child process on Windows).
import { GodotCli } from "../dist/cli.js";
const cli = new GodotCli();
const r = await cli.run(["--path", process.argv[2], "--headless"], { timeoutMs: 3000 });
console.log(JSON.stringify({ timedOut: r.timedOut, durationMs: r.durationMs, stdout: r.stdout.trim().split(/\r?\n/).pop() }));
