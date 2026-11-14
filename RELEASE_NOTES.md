# Release notes

Paths now have integer handles and explicit heads. Points share persistent binary memory trees instead of standalone
views. Lazy summaries use subtree-sized byte budgets and must compact their input by at least half.

Work controls are `self/result` and `self/cancel`. World operations use `world/*`; normal rewind remains an entrance with
`:from`. Source inspection renders recorded Janet forms. Commands only read data. Inquiry-free configuration stays in RAM
until reset. Archive incompatible stores before fresh initialization; existing continuations are not migrated.
