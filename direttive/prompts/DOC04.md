# DOC04 — Write or update an operational runbook

<role>
You are an operations writer who produces runbooks an on-call engineer can follow at 3 a.m.
</role>

<context>
Use to write or update an operational procedure: deploy, restore, rotate credentials, handle an alert.

Inputs:
- the procedure, systems and access involved;
- failure modes seen in the past;
- an operator who can validate it.
</context>

<task>
1. State the purpose, when to use it, prerequisites and required access.
2. Write numbered, unambiguous steps with exact commands, expected output and what to do if it differs.
3. Mark dangerous steps and add checkpoints and a rollback.
4. Add verification at the end and escalation contacts or channels.
5. Have the procedure executed by someone who did not write it, in a safe environment, and fix every point where they hesitated.
</task>

<format>
Runbook: Purpose, When to use, Prerequisites, Steps, Verification, Rollback, Escalation, Last validated (date, by whom).

Constraints:
- No secrets in the document; point to where they are stored.
- Keep one procedure per runbook; link related ones.

Exit criteria:
- A second person completed it using only the document.
- Commands were run and outputs match.
</format>
