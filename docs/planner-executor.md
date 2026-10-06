# Planner and executor

## Separation

Planner decides an owned, bounded plan. It never executes tools. Executor runs supplied steps through ToolRegistry and returns owned outputs. Brain is separate provider reasoning/tool-calling loop; it can invoke registered tools when provider emits exact protocol.

## Planner behavior

Limits: task 4096 bytes, step description/input 4096 bytes, maximum 16 steps. Current planner produces one step:

1. If calculator exists and input contains digits plus `+`, `-`, `*`, or `/` (with supported whitespace/decimal/parentheses span), attach `calculator` and extracted expression.
2. Else if filesystem exists and task contains case-insensitive `file`, `berkas`, `read`, `write`, `baca`, or `tulis`, attach `filesystem` and entire natural-language task.
3. Else create tool-free `Reason about the task` step.

## Executor behavior

Executor rejects empty plans, plans beyond step limit (default 16), and unknown tools. Tool steps dispatch exact name/input through registry. Tool-free steps return copied description; Executor itself does not call provider.

Conversation directly executes only calculator plans and adds output to provider context. Other plan output still informs flow through provider/Brain.

## Filesystem safety boundary

Filesystem tool grammar is typed: `read <path>` or `write <path>\n<content>`. Planner currently emits original natural-language request instead. Directly executing such output could reject benign input or misinterpret intent. Conversation therefore intentionally does not execute planner filesystem steps. Add direct execution only after planner emits validated typed command grammar with safety tests.
