import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import urllib.parse
import uuid

parser = argparse.ArgumentParser(description="Build and configure this Zinc checkout without starting services.")
parser.add_argument("command", choices=("setup", "init", "services"))
parser.add_argument("--models", action="store_true", help="Also install the local llama-server service")
args = parser.parse_args()
if args.models and args.command != "services":
    parser.error("--models is only valid with services")
root = pathlib.Path(__file__).resolve().parent.parent
filename = root / "ac.json"
env = os.environ.copy()
env["PYTHON"] = sys.executable

if args.command == "setup":
    prefix = pathlib.Path.home() / ".local"
    modules = pathlib.Path(env.get("JANET_MODPATH", prefix / "lib/janet")).resolve()
    flags = [
        f"--modpath={modules}",
        f"--binpath={env.get('JANET_BINPATH', prefix / 'bin')}",
        f"--manpath={env.get('JANET_MANPATH', prefix / 'share/man/man1')}",
    ]
    cflags = (
        "/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1"
        if os.name == "nt" else "-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1"
    )
    env.update(JANET_SYSTEM_SQLITE="0", JANET_PATH=str(modules))
    subprocess.run(["jpm", *flags, f"--cflags={cflags}", "deps"], cwd=root, env=env, check=True)
    subprocess.run(["jpm", *flags, "build"], cwd=root, env=env, check=True)
    if not filename.exists():
        text = (root / "examples/ac.json").read_text(encoding="utf-8")
        text = text.replace("${directory}", json.dumps(str(root))[1:-1]).replace("${handle}", str(uuid.uuid4()))
        document = json.loads(text)
        document["policies"]["zinc"]["janet"]["environment"] = {"JANET_PATH": str(modules)}
        with filename.open("x", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2)
            stream.write("\n")
        filename.chmod(0o600)
    for name in ("ac.rego", "models.ini"):
        if not (root / name).exists():
            shutil.copyfile(root / "examples" / name, root / name)
    print(f"Edit your Discord user ID and model settings in {filename}, then run jpm run init.")
else:
    document = json.loads(filename.read_text(encoding="utf-8"))
    settings = list(document["policies"].values())
    if not settings or len({(item["handle"], item["config"]["directory"], item["config"]["store"]) for item in settings}) != 1:
        parser.error("Policies must share one Zinc handle, directory and store")
    env.update(settings[0]["janet"].get("environment", {}))
    if args.command == "init":
        subprocess.run(["janet", "tools/init.janet"], cwd=root, env=env, check=True)
    else:
        (root / "private").mkdir(mode=0o700, exist_ok=True)
        label = "zinc-" + hashlib.sha256(settings[0]["handle"].encode()).hexdigest()[:12]
        endpoint = urllib.parse.urlsplit(document["opa"])
        if endpoint.scheme != "http" or endpoint.hostname not in ("127.0.0.1", "::1", "localhost") or not endpoint.port:
            parser.error("Managed OPA requires an explicit loopback HTTP address and port")
        commands = {
            label + "-opa": [
                "opa", "run", "--server", f"--addr={endpoint.netloc}", "--watch",
                "--log-level=error", str(root / "ac.rego"), str(filename),
            ],
        }
        if args.models:
            model = urllib.parse.urlsplit(settings[0]["config"]["providers"]["llama"]["url"])
            if model.scheme != "http" or model.hostname not in ("127.0.0.1", "::1", "localhost") or not model.port:
                parser.error("Managed llama-server requires an explicit loopback HTTP address and port")
            commands[label + "-models"] = [
                "llama-server", "--host", model.hostname, "--port", str(model.port),
                "--models-preset", str(root / "models.ini"),
            ]
        commands[label] = ["agc", "run", str(root)]
        for name, command in commands.items():
            executable = shutil.which(command[0])
            if not executable:
                parser.error(f"Install {command[0]} and put it on PATH first")
            command[0] = executable
        if sys.platform == "linux":
            directory = pathlib.Path(env.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config")) / "systemd/user"
            directory.mkdir(parents=True, exist_ok=True)
            for name, command in commands.items():
                argv = " ".join(json.dumps(part.replace("%", "%%").replace("$", "$$"), ensure_ascii=False) for part in command)
                dependencies = " ".join(item + ".service" for item in commands if item != label) if name == label else ""
                unit = f"[Unit]\nDescription={name}\nAfter=network-online.target {dependencies}\n"
                if dependencies:
                    unit += f"Requires={dependencies}\n"
                unit += (
                    f"\n[Service]\nType=simple\nKillMode=mixed\nEnvironment={json.dumps('PATH=' + env['PATH'])}\n"
                    f"ExecStart={argv}\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n"
                )
                (directory / (name + ".service")).write_text(unit, encoding="utf-8")
            subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
            print(f"Start: systemctl --user start {label}")
            print(f"Logs: journalctl --user -u {label} -f")
        elif sys.platform == "darwin":
            directory = root / "build/services"
            directory.mkdir(parents=True, exist_ok=True)
            for name, command in commands.items():
                target = directory / ("io.darkhorseprojects." + name + ".plist")
                with target.open("wb") as stream:
                    plistlib.dump({
                        "Label": "io.darkhorseprojects." + name,
                        "ProgramArguments": command,
                        "EnvironmentVariables": {"PATH": env["PATH"]},
                        "RunAtLoad": True,
                        "KeepAlive": {"SuccessfulExit": False},
                        "StandardOutPath": str(root / ("private/" + name + ".log")),
                        "StandardErrorPath": str(root / ("private/" + name + ".error.log")),
                    }, stream)
                print(f"Start: launchctl bootstrap gui/{os.getuid()} {json.dumps(str(target))}")
        elif os.name == "nt":
            for name, command in commands.items():
                executable = command[0].replace("'", "''")
                arguments = subprocess.list2cmdline(command[1:]).replace("'", "''")
                script = (
                    "$ErrorActionPreference = 'Stop'; "
                    f"$action = New-ScheduledTaskAction -Execute '{executable}' -Argument '{arguments}'; "
                    "$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) "
                    "-RestartCount 10 -RestartInterval (New-TimeSpan -Seconds 5); "
                    f"Register-ScheduledTask -TaskName '{name}' -Action $action -Settings $settings -Force"
                )
                subprocess.run([
                    "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand",
                    base64.b64encode(script.encode("utf-16le")).decode(),
                ], check=True)
                print(f"Start: Start-ScheduledTask -TaskName {name}")
        else:
            parser.error("Service installation supports Linux/systemd, macOS/launchd and Windows Task Scheduler")

print(f"Configuration: {filename}\nAuthorization: {root / 'ac.rego'}\nModel preset: {root / 'models.ini'}")
print("Nothing has been started. Start OPA and your model server, then run:")
print(subprocess.list2cmdline(["agc", "run", str(root)]))
