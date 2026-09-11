# tools/hooks/ — the one git hook

`pre-push` refuses a push that changes `tsp/` or `tools/` without the smoke gate having passed against
those exact bytes.

```sh
ln -sf ../../tools/hooks/pre-push .git/hooks/pre-push
```

**Cloning does not install it.** Git runs hooks only out of `.git/hooks`, which is not tracked, so the
symlink is a per-clone step.

Three outcomes, in the order it tries them:

* `SMOKE_OVERRIDE="why" git push` prints the reason and exits 0 — the point being that the reason lands in
  the terminal and the decision is on the record.
* A push whose commits touch neither `tsp/` nor `tools/` is exempt automatically. It reads the range being
  pushed off stdin, not `git diff HEAD`: judging by the working tree would exempt a push whose commits
  touch `tsp/` merely because nothing is uncommitted, which is exactly backwards. A new branch or a ref
  delete has no range worth trusting and falls through to the check.
* Everything else has to satisfy `python3 tools/smoke_receipt.py --verify`.

The receipt is content-addressed over the **working tree**, so the one-line fix made *after* the smoke run
invalidates it — the case worth catching, because that line is the least tested thing in the push. Staging
or committing the same bytes does not invalidate it, which is the case that must not be caught.
