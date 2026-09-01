# examples

`self-test.yml` is the workflow that exercises this action end to end: restore, write a new
timestamp, refresh, and read back the *new* timestamp on the following run. Copy it to
`.github/workflows/self-test.yml` to run it.

It lives here rather than under `.github/workflows/` because the token used to publish this
repository does not hold the `workflow` OAuth scope, and GitHub rejects pushes that create or
modify files under `.github/workflows/` without it.
