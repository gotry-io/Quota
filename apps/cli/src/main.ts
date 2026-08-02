#!/usr/bin/env node

import { runCli } from "./commands.ts";

process.exitCode = await runCli(process.argv.slice(2));
