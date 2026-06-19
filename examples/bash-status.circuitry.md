---
circuitry: "0.8.2"
name: bash status

in:
  - $command

shell:
  status:
    surface: unix-bash.bash
    in:
      command: $command
    command: $command
    out:
      output: $output
      exit: $exit

out:
  - $output
  - $exit
---

# Bash status

Runs one Bash command through the `unix-bash.bash` package surface.
