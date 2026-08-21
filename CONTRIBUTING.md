# Contributing

The most useful contribution is **a reading from a setup that isn't mine**: a
different engine, a different install location, an Intel Mac, a version of `lms`
or LocalAI that reports something new.

```sh
llmctl status --json          # what the tool sees
python3 -m unittest discover -s tests -v
```

Paste the JSON along with your macOS version and which engines you run. It
contains model names and byte counts — no prompts, no keys, no paths outside your
engine directories.

## The rules this tool lives by

- **A measurement is a number; the absence of one is stated.** Unknown busy
  state, unreadable engine, missing CLI — each is reported as itself, never as
  zero and never as idle.
- **Never launch what you are monitoring.** `lms` starts LM Studio if it is not
  running. Four tests exist to keep that from coming back; don't route around
  them.
- **Never stop something that might be working.** A server whose state cannot be
  read is `unknown`, and `unknown` is not stoppable.
- **Never touch a process the tool does not understand.** Large non-AI processes
  are listed for a human to judge. That is the whole feature.

## Tests

New parsing goes in `tests/`, and every test must be a pure function over text —
no shelling out, so the suite runs on a machine with no engine installed. If you
found a case where some program printed something misleading, add the test that
fails on the naive reading first.

## Sign your work (DCO)

Add a `Signed-off-by` line to each commit — `git commit -s` does it for you:

```
Signed-off-by: Your Name <your.email@example.com>
```

That line is the [Developer Certificate of Origin](https://developercertificate.org/):
you are stating that you wrote the patch, or otherwise have the right to submit
it under this project's licence (MIT). It is one line, not a copyright
assignment — you keep the copyright in your own work.
