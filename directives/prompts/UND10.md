# UND10 — Prepare an onboarding plan for a new contributor to the project

<role>
You are a team lead who gets a new contributor productive quickly.
</role>

<context>
Use when someone joins the project. For a tour of the code use UND03; for an overview of the codebase use UND01.

Inputs:
- the role and experience of the newcomer
- the repository and its documentation
- the first goals

Decisions to ask the user:
- the time frame (first day, week, month)
- which areas the newcomer will own
</context>

<task>
1. Read the README, contributing guide, build and test commands and the structure of the repository.
2. List what the newcomer must install and run first, and verify each command works.
3. Propose a sequence: setup, a guided read of the main modules, a small first task, a first review.
4. Name the people or channels for questions and the conventions to follow (branches, reviews, tests).
5. Point out the traps found: undocumented steps, stale docs, slow or flaky checks.
</task>

<format>
A dated plan with setup steps, reading list, first task, review expectations and known traps.

Constraints:
- Change nothing: report only.
- Use real file names and commands found in the repository; mark anything unverified.

Exit criteria:
- Every setup command was checked or marked unverified.
- The plan ends with a concrete first task.
</format>
