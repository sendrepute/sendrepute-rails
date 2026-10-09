import { visibleEmailText } from "../../../artifacts/api-server/src/lib/classifier-features.ts";
import { readFileSync } from "node:fs";

const body = JSON.parse(readFileSync(0, "utf8"));
process.stdout.write(JSON.stringify(visibleEmailText(body)));