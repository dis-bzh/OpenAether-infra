<!-- What changes, and why. "Refs #N" for an issue this does not finish: a
     closing keyword followed by #N closes it on merge, even inside a sentence. -->

## Rung

<!-- The highest rung the head commit reached, exactly one of:
       mocked | emulated | local Docker | real cloud
     (CONTRIBUTING.md, "The one rule"). For mocked, write the word and paste
     nothing: CI runs those targets as required checks of their own, and the
     "Rung receipt" check does not wait for them (a docs-only diff runs none:
     write `none (reason)`). For any higher rung,
     paste what `task receipts` prints: the check fails when the declared rung
     has no green receipt for the head commit, or a pasted run at or below it
     is red: after a push, re-run and paste again. Editing this body re-runs
     only that check, not CI.
     A docs-only diff may write `none (reason)` instead (a space before the bracket). -->
Rung:

```receipts
```

**Skipped, and why:**
