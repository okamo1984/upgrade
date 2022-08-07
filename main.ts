import {
  dirname,
  ensureDirSync,
  green,
  parse,
  readAllSync,
  resolve,
} from "./deps.ts";

const flags = parse(Deno.args);
const homeDir = Deno.env.get("HOME");
if (!homeDir) {
  console.error("`HOME` environment is not set");
  Deno.exit(1);
}

const configPath = resolve(homeDir, ".ug", "cmd.json");

function setUpgradeCommand(name: string, command: string) {
  ensureDirSync(dirname(configPath));
  const configFile = Deno.openSync(configPath, {
    read: true,
    write: true,
    create: true,
  });
  const decoder = new TextDecoder("utf-8");
  const contents = decoder.decode(readAllSync(configFile));
  let config: Record<string, string> = {};
  if (contents) {
    config = JSON.parse(contents);
  }
  configFile.close();
  config[name] = command;
  const encoder = new TextEncoder();
  Deno.writeFileSync(configPath, encoder.encode(JSON.stringify(config)));
}

function unsetUpgradeCommand(name: string) {
  try {
    const config: Record<string, string> = JSON.parse(
      Deno.readTextFileSync(configPath),
    );
    delete config[name];
    const encoder = new TextEncoder();
    Deno.writeFileSync(configPath, encoder.encode(JSON.stringify(config)));
  } catch (err) {
    console.error(err);
  }
}

function listUpgradeCommand() {
  try {
    const config: Record<string, string> = JSON.parse(
      Deno.readTextFileSync(configPath),
    );
    const maxKeyLength = Math.max(...Object.keys(config).map((k) => k.length));
    console.log(
      Object.entries(config)
        .map(
          (e) =>
            `${e[0] + " ".repeat(maxKeyLength - e[0].length)} = ${green(e[1])}`,
        )
        .join("\n"),
    );
  } catch (err) {
    console.error(err);
  }
}

async function runUpgradeCommand(name: string) {
  try {
    const config: Record<string, string> = JSON.parse(
      Deno.readTextFileSync(configPath),
    );
    const command = config[name];
    if (!command) {
      throw Error(`${name} is not registered`);
    }
    const pipes = command.split("|").map((pipe) => pipe.trim().split(" "));
    if (!pipes.slice(1).length) {
      const child = spawn(pipes[0]);
      child.stdout.pipeTo(Deno.stdout.writable);
      child.stderr.pipeTo(Deno.stderr.writable);
      await wait(child);
      Deno.exit(0);
    }

    const children: Deno.Child[] = [];
    for (let i = 0; i < pipes.length - 1; i++) {
      const child = spawn(pipes[i]);
      const pipe = spawn(pipes[i + 1]);
      child.stdout.pipeThrough({
        writable: pipe.stdin,
        readable: pipe.stdout,
      });
      if (i === pipes.length - 2) {
        pipe.stdout.pipeTo(Deno.stdout.writable);
        pipe.stderr.pipeTo(Deno.stderr.writable);
      }
      children.push(child);
      children.push(pipe);
    }
    for (const child of children) {
      await wait(child);
    }
    Deno.exit(0);
  } catch (err) {
    console.error(err);
  }
}

function spawn(command: string[]): Deno.Child {
  return Deno.spawnChild(command[0], {
    args: command.slice(1),
    stdin: "piped",
  });
}

async function wait(child: Deno.Child) {
  const status = await child.status;
  if (status.code !== 0) {
    Deno.exit(status.code);
  }
}

async function ug() {
  const command = flags._[0] as string;
  if (!command) {
    console.error(
      "sub command is not set, available commands are `set`, `unset`",
    );
    Deno.exit(1);
  }
  if (command === "set") {
    setUpgradeCommand(flags.name, flags.command);
  } else if (command === "unset") {
    unsetUpgradeCommand(flags.name);
  } else if (command === "list") {
    listUpgradeCommand();
  } else {
    await runUpgradeCommand(command);
  }
}

ug();
