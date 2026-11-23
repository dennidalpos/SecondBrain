# Prompt catalog

Index generated from catalog.json and the Markdown cards with scripts/build-prompts.ps1. Do not edit this index by hand.

In the chat: `sb prompt`, `sb prompt list`, `sb prompt area quality`, `sb prompt show REV01`, `sb prompt REV01: description`. Every prompt has an immutable ID (`pmt-` and 8 hex digits) and a stable code that is never reused: ID and code resolve to the same prompt. Codes are rewritten without aliases in 4.0: an old code is unknown.

The CLI composes text; the task is carried out by the agent within the permissions and mode of the session. [How to use and edit the prompts](../../docs/prompt.md).

```text
Prompt catalog
Legend: 🔭 reads · ✅ verifies · 🔥 writes · ⛔ destructive/irreversible

== CURRENT REPOSITORY: RUN FROM THE REPOSITORY YOU WORK ON ==

UNDERSTAND CODE AND PROJECTS
🔭 UND01 | Explore the repository and identify main components and commands
  • ID: pmt-a709a792
  • Scope: repo | Mode: read
  • Needs: read access to the repository and a shell
  • Example: explore the structure and main modules

🔭 UND02 | Trace a flow and its dependencies through the code
  • ID: pmt-e0fd59da
  • Scope: repo | Mode: read
  • Needs: entry point or scenario to trace
  • Example: trace the authentication and session flow

🔭 UND03 | Give a guided tour of the code or a concept for someone new to it
  • ID: pmt-fe04425a
  • Scope: repo | Mode: read
  • Needs: The code, module or concept to explain and the reader's starting level
  • Example: UND03: explain how the payment retry flow works to a new teammate

🔭 UND04 | Find official sources that fit the technical problem
  • ID: pmt-25c97d58
  • Scope: repo | Mode: read
  • Needs: technical problem or library with its version
  • Example: find the official documentation for the runtime version in use

🔭 UND05 | Analyze logs and incidents to find the root cause, without changing code
  • ID: pmt-1839927a
  • Scope: repo | Mode: read
  • Needs: logs, errors or symptoms of the incident, time window and read access
  • Example: find the root cause of yesterday's errors in the logs

🔭 UND06 | Assess the impact, risks and dependencies of a change
  • ID: pmt-179b9acc
  • Scope: repo | Mode: read
  • Needs: proposed change or defect to fix
  • Example: assess the impact of isolating runtime logs

🔭 UND07 | Summarize recent repository activity: commits, issues and pull requests
  • ID: pmt-3ceaaf30
  • Scope: repo | Mode: read
  • Needs: read access to the Git history and, if available, the GitHub issues and pull requests
  • Example: summarize what changed in the repository since the last release

🔭 UND08 | Synthesize findings from several sources into one cited summary
  • ID: pmt-9dfb369b
  • Scope: repo | Mode: read
  • Needs: the sources to read and the question to answer
  • Example: synthesize these three design documents into a one-page summary

🔭 UND09 | Diagnose invalid structured data (JSON, YAML, CSV) and propose the fix
  • ID: pmt-6301bbfc
  • Scope: repo | Mode: read
  • Needs: the invalid data and the parser or schema that rejects it
  • Example: this config.json fails to load: find out why

🔭 UND10 | Prepare an onboarding plan for a new contributor to the project
  • ID: pmt-6fced11d
  • Scope: repo | Mode: read
  • Needs: the repository and a description of the newcomer
  • Example: plan the first two weeks of a backend developer joining this repository

🔭 UND11 | Triage a defect report: reproduce it, classify it and stop before any fix
  • ID: pmt-3a124c64
  • Scope: repo | Mode: read
  • Needs: a defect report with version and environment
  • Example: triage this crash report and tell me whether it reproduces

🔭 UND12 | Run a retrospective on a finished piece of work
  • ID: pmt-66080f17
  • Scope: repo | Mode: read
  • Needs: the work to review and its history
  • Example: run a retrospective on the last release


REQUIREMENTS, DESIGN AND PLANNING
🔭 PLN01 | Turn a request into requirements and acceptance criteria
  • ID: pmt-98071f85
  • Scope: repo | Mode: read
  • Needs: user request and existing documentation
  • Example: define acceptance criteria for full-text search

🔭 PLN02 | Explore two or three ways to implement a feature before choosing one
  • ID: pmt-b120a366
  • Scope: repo | Mode: read
  • Needs: the feature description and the code it touches
  • Example: compare ways to add offline support to this app

🔭 PLN03 | Compare architectural options and justify a decision
  • ID: pmt-3e0ad55e
  • Scope: repo | Mode: read
  • Needs: alternatives to evaluate and project constraints
  • Example: compare SQLite and JSON for local persistence

🔥 PLN04 | Design API contracts, data models and compatibility
  • ID: pmt-83764c0d
  • Scope: repo | Mode: write
  • Needs: requirements or current schema with its version
  • Example: design the JSON schema and API contracts for the task list

🔭 PLN05 | Plan a change before editing: phases, checks and rollback, no edits
  • ID: pmt-8541aed1
  • Scope: repo | Mode: read
  • Needs: a goal and access to the code
  • Example: plan the move from REST polling to webhooks

🔭 PLN06 | Plan a structural refactoring in phases, with seams and characterization tests
  • ID: pmt-78b7d0ac
  • Scope: repo | Mode: read
  • Needs: the code to restructure and the target structure
  • Example: plan splitting the billing module out of the monolith

🔥 PLN07 | Record an architecture decision (ADR)
  • ID: pmt-c61c598b
  • Scope: repo | Mode: write
  • Needs: The decision made or to make, its context, constraints, options considered and who decides
  • Example: PLN07: record why we chose PostgreSQL over MongoDB

🔭 PLN08 | Turn an issue or request into an implementation plan, without editing code
  • ID: pmt-2330fcf1
  • Scope: repo | Mode: read
  • Needs: an issue or request and read access to the code
  • Example: plan the work for issue 214


CHANGE CODE
🔥 BLD01 | Implement a feature from an approved plan or issue, with tests
  • ID: pmt-83df1685
  • Scope: repo | Mode: write
  • Needs: verified requirements or acceptance criteria
  • Example: implement the export command with hash validation

🔥 BLD02 | Reproduce a defect as a failing test or deterministic script
  • ID: pmt-c1acc990
  • Scope: repo | Mode: write
  • Needs: a triaged defect and write access to the tests
  • Example: write a failing test for the date parsing bug

🔥 BLD03 | Fix a defect at its cause with the smallest correct change
  • ID: pmt-25ac264e
  • Scope: repo | Mode: write
  • Needs: a reproducible defect and write access to the code
  • Example: fix the failing test for the date parsing bug

🔥 BLD04 | Refactor one component in small batches, keeping behavior and contracts
  • ID: pmt-2b07a693
  • Scope: repo | Mode: write
  • Needs: a component, a green build and write access
  • Example: refactor the invoice formatter keeping its output identical

🔥 BLD05 | Reduce the complexity of a long or deeply nested method
  • ID: pmt-9ad9b9a2
  • Scope: repo | Mode: write
  • Needs: a method, tests and write access
  • Example: simplify the order validation method

🔥 BLD06 | Refactor code to a design pattern that removes a concrete problem
  • ID: pmt-99356597
  • Scope: repo | Mode: write
  • Needs: code with a concrete structural problem
  • Example: replace the payment type switch with a pattern

🔥 BLD07 | Decouple a data access layer from business logic
  • ID: pmt-8df08078
  • Scope: repo | Mode: write
  • Needs: code and write access
  • Example: separate SQL from the order service

🔥 BLD08 | Simplify a deep inheritance hierarchy
  • ID: pmt-f3194a3b
  • Scope: repo | Mode: write
  • Needs: the classes and write access
  • Example: flatten the notification classes

🔥 BLD09 | Translate code to another programming language preserving behavior
  • ID: pmt-c498b6e7
  • Scope: repo | Mode: write
  • Needs: source code and the target language
  • Example: translate this parser from Python to Go

🔥 BLD10 | Migrate code or a framework to a defined target
  • ID: pmt-22863973
  • Scope: repo | Mode: write
  • Needs: source and target versions with release notes
  • Example: migrate the scripts from the old runtime version to the current one

🔥 BLD11 | Update dependencies checking compatibility and regressions
  • ID: pmt-e2405036
  • Scope: repo | Mode: write
  • Needs: dependency manifests and lock files
  • Example: update the JSON serialization package

🔥 BLD12 | Scaffold new modules with structure, configuration and tests
  • ID: pmt-884419a5
  • Scope: repo | Mode: write
  • Needs: agreed architectural scope and dependencies
  • Example: define the scaffolding of the new module

🔥 BLD13 | Optimize one measured performance hotspot and keep the gain only if proven
  • ID: pmt-ab57f985
  • Scope: repo | Mode: write
  • Needs: a benchmark and write access
  • Example: speed up the report export


TESTS AND VERIFICATION
🔥 QUA01 | Add unit and integration tests for the relevant risks
  • ID: pmt-08bff671
  • Scope: repo | Mode: write
  • Needs: test harness and the behavior to verify
  • Example: add boundary tests for the budget calculation

🔥 QUA02 | Cover user journeys with end-to-end tests
  • ID: pmt-286c3225
  • Scope: repo | Mode: write
  • Needs: test environment and agreed user flows
  • Example: create an end-to-end test for the backup and restore cycle

🔭 QUA03 | Find untested code and weak tests, ranked by risk
  • ID: pmt-de5f1d8d
  • Scope: repo | Mode: read
  • Needs: the code and its tests
  • Example: find the untested functions in the notification service

🔥 QUA04 | Create mocks and test doubles to isolate a layer in unit tests
  • ID: pmt-c1b87f1a
  • Scope: repo | Mode: write
  • Needs: code to test and write access to the tests
  • Example: create fakes for the payment gateway in tests

🔭 QUA05 | Diagnose a failing CI run from its logs, without changing code
  • ID: pmt-bd98736f
  • Scope: repo | Mode: read
  • Needs: access to the CI logs or the failing output
  • Example: diagnose why the windows job fails on main

✅ QUA06 | Verify real behavior against the requirements
  • ID: pmt-ef96dea5
  • Scope: repo | Mode: verify
  • Needs: acceptance criteria and a working environment
  • Example: verify that the output conforms to the specifications

🔭 QUA07 | Audit performance with a repeatable benchmark and ranked bottlenecks
  • ID: pmt-2eb73728
  • Scope: repo | Mode: read
  • Needs: a scenario and a way to run it
  • Example: audit the startup time of the desktop app

🔥 QUA08 | Build or review an LLM feature with an evaluation set
  • ID: pmt-0715c64b
  • Scope: repo | Mode: write
  • Needs: The LLM or agent feature, model and provider, expected behavior, failure cases and sample inputs
  • Example: QUA08: add an evaluation set for the support bot before changing its prompt


REVIEW AND AUDIT
🔭 REV01 | Review a change for correctness, security and tests
  • ID: pmt-27896824
  • Scope: repo | Mode: read
  • Needs: a change to review
  • Example: review pull request 123

🔭 REV02 | Review existing code for maintainability, as a newcomer would read it
  • ID: pmt-ac3e0b5b
  • Scope: repo | Mode: read
  • Needs: code to review
  • Example: review the maintainability of the scheduler module

🔭 REV03 | Audit architecture and technical debt not yet tracked
  • ID: pmt-c692cc23
  • Scope: repo | Mode: read
  • Needs: read access to the code, the backlog and architecture documentation
  • Example: audit of architecture and technical debt of the repository

🔭 REV04 | Audit dependencies: outdated, vulnerable and unused
  • ID: pmt-7dc63766
  • Scope: repo | Mode: read
  • Needs: manifests, lock files and access to package registries or dependency advisories
  • Example: dependency audit before the upgrade

🔭 REV05 | Audit the CI/CD pipeline and supply chain
  • ID: pmt-6b494996
  • Scope: repo | Mode: read
  • Needs: Pipeline definitions, workflow permissions, secrets handling, third-party actions and release process
  • Example: REV05: audit the GitHub Actions workflows for unpinned actions and excess permissions

🔭 REV06 | Measure the repository with reproducible metrics and find hotspots
  • ID: pmt-4a9a4b4f
  • Scope: repo | Mode: read
  • Needs: read access to the repository, its Git history and measurement tools
  • Example: metrics and hotspots of the repository

🔭 REV07 | Audit whether documentation still matches the code
  • ID: pmt-2f314fdb
  • Scope: repo | Mode: read
  • Needs: the documents and the code
  • Example: audit the README against the current CLI

🔭 REV08 | Detect breaking changes in a public API between two versions
  • ID: pmt-bafe9bd1
  • Scope: repo | Mode: read
  • Needs: two versions of an API
  • Example: compare the public API of v2.3 and v3.0

🔭 REV09 | Find unused code and repository leftovers, without deleting anything
  • ID: pmt-40772e6e
  • Scope: repo | Mode: read
  • Needs: a repository and read access
  • Example: find unused code in the services folder

🔭 REV10 | Merge audit findings into one report with a ranked remediation plan
  • ID: pmt-856042e3
  • Scope: repo | Mode: read
  • Needs: The findings of the audit cards already run, in this session or saved as files, and the checkout
  • Example: REV10: merge the audit findings into one report with a remediation plan


SECURITY, PRIVACY AND LICENSES
🔭 RSK01 | Analyze threats, trust boundaries and abuse scenarios
  • ID: pmt-deb7d01a
  • Scope: repo | Mode: read
  • Needs: architecture and data flows toward the outside
  • Example: threat model of the stdio and local file system flows

🔭 RSK02 | Find vulnerabilities in code and rank them with a suggested fix
  • ID: pmt-fe014372
  • Scope: repo | Mode: read
  • Needs: the code to review
  • Example: look for injection issues in the API handlers

🔥 RSK03 | Fix a confirmed vulnerability at its root, with a failing test first
  • ID: pmt-b4cb6659
  • Scope: repo | Mode: write
  • Needs: a confirmed vulnerability and write access
  • Example: fix the path traversal reported in the upload handler

✅ RSK04 | Find exposed credentials in the tree and the history
  • ID: pmt-73fb4547
  • Scope: repo | Mode: verify
  • Needs: a repository to scan
  • Example: scan this repository for leaked tokens

✅ RSK05 | Verify personal data isolation and compliance with GDPR and policies
  • ID: pmt-24189cb6
  • Scope: repo | Mode: verify
  • Needs: data mapping and compliance policy
  • Example: check for personal data and GDPR privacy compliance

🔭 RSK06 | Review repository security settings against a baseline, read-only
  • ID: pmt-c356eede
  • Scope: repo | Mode: read
  • Needs: read access to the repository settings
  • Example: review the security settings of this repository

✅ RSK07 | Check for sensitive data before publishing, locally and on the remote
  • ID: pmt-058c474f
  • Scope: repo | Mode: verify
  • Needs: Commits, index, working tree and history to publish; remote destination and visibility; scanning tools available
  • Example: RSK07: check the commits about to be pushed, and the remote, for sensitive data

✅ RSK08 | Check licenses and compatibility of the project and its dependencies
  • ID: pmt-adb9bfc0
  • Scope: repo | Mode: verify
  • Needs: dependency manifests and the project license
  • Example: check the licenses of the dependencies before the release


DATA AND APIS
🔭 DTA01 | Plan a schema and data migration with verification and rollback
  • ID: pmt-32e3cf59
  • Scope: repo | Mode: read
  • Needs: the current and target data models
  • Example: plan the move of user data to the new schema

🔥 DTA02 | Integrate API services with error handling and request retries
  • ID: pmt-6b7b0e8d
  • Scope: repo | Mode: write
  • Needs: API documentation, test credentials and schema
  • Example: implement a REST client with exponential backoff and retry

🔭 DTA03 | Analyze slow queries and propose indexes and rewrites, without applying
  • ID: pmt-6b6c2ade
  • Scope: repo | Mode: read
  • Needs: the slow queries and database access
  • Example: analyze why the order search is slow


INTERFACE AND ACCESSIBILITY
🔭 UIX01 | Assess usability, consistency and states of user flows
  • ID: pmt-33216f62
  • Scope: repo | Mode: read
  • Needs: runnable application and flows to examine
  • Example: assess the usability of the setup wizard

✅ UIX02 | Verify accessibility and keyboard and assistive-technology use
  • ID: pmt-2ea0c993
  • Scope: repo | Mode: verify
  • Needs: working interface and reference standards
  • Example: verify ARIA conformance and accessibility

✅ UIX03 | Verify internationalization of strings, formats and translations
  • ID: pmt-805ca095
  • Scope: repo | Mode: verify
  • Needs: interface or messages with supported languages and formats
  • Example: verify the strings, formats and translations of the CLI


DOCUMENTATION AND DIAGRAMS
🔥 DCM01 | Write guides and READMEs consistent with the real product
  • ID: pmt-07430e8c
  • Scope: repo | Mode: write
  • Needs: implemented features, verified commands and approved screenshots
  • Example: update the guides and add Mermaid flow diagrams

🔥 DCM02 | Document APIs and contracts from the implementation
  • ID: pmt-6e82e3a9
  • Scope: repo | Mode: write
  • Needs: source code of the contracts and endpoints
  • Example: document the parameters and response schemas of the endpoints

🔥 DCM03 | Create a diagram from the real code and check it against the code
  • ID: pmt-d586ebc5
  • Scope: repo | Mode: write
  • Needs: the code and the diagram format
  • Example: draw the request flow of the API as a sequence diagram

🔭 DCM04 | Survey a repository and propose its specific agent directives
  • ID: pmt-e9de72a0
  • Scope: repo | Mode: read
  • Needs: the checkout, the global and common directive blocks, the current AGENTS.md and dossier directives, the startup budget
  • Example: DCM04: survey this repository and propose the directives agents need here beyond the common blocks


RELEASE, PIPELINES AND INCIDENTS
🔥 REL01 | Prepare release notes and delivery checks
  • ID: pmt-0618969e
  • Scope: repo | Mode: write
  • Needs: commits, issues or tasks completed since the previous release
  • Example: compile the v1.1 release notes from commits and issues

🔥 REL02 | Configure pipelines, containers and infrastructure as code
  • ID: pmt-ce00f261
  • Scope: repo | Mode: write
  • Needs: deployment requirements and target environment
  • Example: configure a multi-stage Dockerfile for a reproducible build

🔥 REL03 | Write a blameless incident postmortem
  • ID: pmt-28f4fbf5
  • Scope: repo | Mode: write
  • Needs: Incident timeline, impact, logs or alerts, the fix applied and the people involved
  • Example: REL03: write the postmortem for last night's checkout outage


GIT AND GITHUB
🔭 GIT01 | Write a conventional commit message from the staged changes
  • ID: pmt-9280ba2e
  • Scope: repo | Mode: read
  • Needs: staged changes
  • Example: write a commit message for what I staged

🔥 GIT02 | Prepare commits and pull requests with verified scope, message and checks
  • ID: pmt-3e3728b6
  • Scope: repo | Mode: write
  • Needs: local changes to deliver and an explicit request for a commit or pull request
  • Example: prepare the commits and the pull request description

🔭 GIT03 | Triage open issues and pull requests
  • ID: pmt-f8dd6843
  • Scope: repo | Mode: read
  • Needs: GitHub repository with gh authenticated, labels, project rules, age and activity of issues and PRs
  • Example: GIT03: triage open issues and PRs and propose labels and closures


SB SYSTEM: SESSIONS
🔭 SES01 | Start a session: context, repository state, alignment and next tasks
  • ID: pmt-5916b85a
  • Scope: repo | Mode: read
  • Needs: any folder; a managed repository adds the dossier, the tracker and the alignment check
  • Example: SES01: start the session in this repository and propose the next tasks

🔥 SES02 | Close the session with memories, tracker and handoff updated
  • ID: pmt-76604e4a
  • Scope: repo | Mode: write
  • Needs: state of the work done, defined next tasks and delivery destination
  • Example: sb prompt SES02: close the session and ask for commit and push

🔥 SES03 | Stop the agent and hand the session over to another IDE or account
  • ID: pmt-039a5879
  • Scope: repo | Mode: write
  • Needs: the task in progress, the Git state of the checkout and the person's choice for uncommitted work
  • Example: sb stop: I am at the end of my weekly limit, save the session so I can resume from another account

🔥 SES04 | Resume work stopped by a usage limit, importing it from another account
  • ID: pmt-d0c0d000
  • Scope: repo | Mode: write
  • Needs: the stopped work (MEM09 or MEM03 report, runner resume.json, branch or worktree) and the import method the person picks
  • Example: SES04: the runner stopped for quota on the other account, import its work and continue the task


SB SYSTEM: TASKS, MEMORY AND TRACKER
🔭 TRK01 | Read memory, context and tracker of the current repository and list its tasks
  • ID: pmt-821f7dec
  • Scope: repo | Mode: read
  • Needs: checkout of the open repository
  • Example: sb prompt TRK01: load the repository context and list the ready tasks

🔥 TRK02 | Complete the next ready task of the open repository
  • ID: pmt-4cc383ba
  • Scope: repo | Mode: write
  • Needs: planned task and acceptance criteria
  • Example: run the next priority task that can be done autonomously

🔭 TRK03 | Inspect the repo and find leftover tasks against the real code
  • ID: pmt-cc2c5f5a
  • Scope: repo | Mode: read
  • Needs: working tree, recent history and any backlog or notes
  • Example: inspect the repo and detect leftover tasks

🔥 TRK04 | Run ready autonomous tasks with the runner and record the outcome
  • ID: pmt-802ff569
  • Scope: repo | Mode: write
  • Needs: ready autonomous tasks, the desktop runner (scripts/runner.ps1) or the command line (run-ready-tasks.ps1, launcher) and the user's go-ahead for -Run
  • Example: TRK04: run the ready autonomous tasks, follow the run and record the outcome

🔥 TRK05 | Unblock blocked tasks: verify the real reason, then make them autonomous
  • ID: pmt-876bccc6
  • Scope: repo | Mode: write
  • Needs: tracker with blocked tasks, their state reasons and acceptance criteria, and the answers of the user to a structured interview
  • Example: TRK05: review the blocked tasks and make the ones without a real prerequisite autonomous

🔥 TRK06 | Reorder the tracker: development first, qualifications after
  • ID: pmt-c1e1e70c
  • Scope: repo | Mode: write
  • Needs: tracker with its archive, the priority scheme chosen by the user and the list of tasks with real prerequisites
  • Example: TRK06: archive the done tasks and move qualifications below development

🔭 TRK07 | Analyze a non-runnable task and ask what makes it autonomous
  • ID: pmt-cca5cbfd
  • Scope: repo | Mode: read
  • Needs: one task the runner skips, its reason and dependencies, the checkout read-only and the owner's answers to multiple-choice questions
  • Example: TRK07: analyze task #42 and ask me only what is needed to make it autonomous

🔥 TRK08 | Prepare tasks for unattended runs, one at a time
  • ID: pmt-210af3b0
  • Scope: repo | Mode: write
  • Needs: candidate tasks from `sb queue -Candidates`, the checkout read-only, the owner's answers to multiple-choice questions and the owner's go-ahead to start
  • Example: TRK08: make the next tasks autonomous one by one, stop at 5, then start the queue

🔥 TRK09 | Reconcile conflicting or invalid queued writes and orphan receipts
  • ID: pmt-a76062d2
  • Scope: repo | Mode: write
  • Needs: a managed repository and a write session to apply
  • Example: sb reconcile tasks: plan the queued conflicts of this repository

🔥 TRK10 | Align local instructions, context, memory and tracker
  • ID: pmt-f02db9d0
  • Scope: repo | Mode: write
  • Needs: recent decisions or changes not yet recorded
  • Example: sb prompt TRK10: align context.md and memory.md after completing a task

🔥 TRK11 | Remove the greenfield lock and apply the version rule again
  • ID: pmt-29b3278f
  • Scope: repo | Mode: write
  • Needs: managed repository, active dossier and user confirmation
  • Example: sb prompt TRK11: remove the greenfield lock on this repository

🔥 TRK12 | Apply a tracker triage: close integrated tasks, cancel the non-integrable
  • ID: pmt-f19b9c51
  • Scope: repo | Mode: write
  • Needs: The TRK03 triage report, the tracker and the working tree
  • Example: TRK12: apply the tracker triage and close the tasks already integrated

🔥 TRK13 | Set the greenfield lock (versions, changelog, migrations, aliases)
  • ID: pmt-33766c25
  • Scope: repo | Mode: write
  • Needs: managed repository, active dossier and user confirmation
  • Example: sb prompt TRK13: set the greenfield lock on this repository


WEBSITES AND WEB APPS (OPTIONAL PACK)
🔥 SIT01 | Define the requirements, audience and success criteria of a site or app
  • ID: pmt-ca497b4e
  • Scope: repo | Mode: write
  • Needs: a brief of the site or app, its audience and constraints, and write access to the docs folder
  • Example: SIT01: define the requirements and success criteria of the new company website

🔥 SIT02 | Choose the stack, hosting and architecture of a site or app with trade-offs
  • ID: pmt-68ab97c9
  • Scope: repo | Mode: write
  • Needs: the requirements (WEB01), team skills, budget and hosting constraints
  • Example: SIT02: compare stacks and hosting for the new site and record the decision

🔥 SIT03 | Design information architecture, user flows, content and a small design system
  • ID: pmt-203f2c25
  • Scope: repo | Mode: write
  • Needs: the requirements (WEB01), the chosen architecture and any brand assets
  • Example: SIT03: design the sitemap, key flows and design tokens for the new site

🔥 SIT04 | Scaffold the project and build a first working vertical slice
  • ID: pmt-1ea75934
  • Scope: repo | Mode: write
  • Needs: architecture and design decisions, an empty or new repository and a working toolchain
  • Example: SIT04: scaffold the project and deliver the first page end to end with tests

🔥 SIT05 | Develop the remaining features in phases with tests and accessibility checks
  • ID: pmt-9deb1414
  • Scope: repo | Mode: write
  • Needs: the first vertical slice (WEB04), a phased backlog and a working test setup
  • Example: SIT05: build the next phase of features and verify tests and accessibility

🔥 SIT06 | Prepare release, hosting, monitoring, backups and handover of a site or app
  • ID: pmt-019f989e
  • Scope: repo | Mode: write
  • Needs: a built and tested application, the hosting target and the delivery owner
  • Example: SIT06: prepare the production release, monitoring and handover notes

🔥 SIT07 | Harden a website against common attacks and abuse
  • ID: pmt-5dfba80d
  • Scope: repo | Mode: write
  • Needs: the site code and configuration, its hosting target and write access to the repository
  • Example: SIT07: harden the company website before the public launch

🔥 SIT08 | Verify and update site indexing: sitemap, robots, webmaster tools, schema
  • ID: pmt-f7a96c3d
  • Scope: repo | Mode: write
  • Needs: the live or staging site, the domain owner's access to the search tools, write access to the repository
  • Example: SIT08: verify what is indexed and update sitemap, robots and webmaster tools

🔥 SIT09 | Control AI crawlers and bots on a website
  • ID: pmt-f1fdcecb
  • Scope: repo | Mode: write
  • Needs: the site, its access logs or CDN/WAF console and the owner's policy on AI use of content
  • Example: SIT09: block AI training crawlers on the site and verify the rules in the logs


AI FEATURES AND COMPANY AI (OPTIONAL PACK)
🔭 LLM01 | Rank company AI use cases by data readiness and feasibility
  • ID: pmt-9e1ebedb
  • Scope: repo | Mode: read
  • Needs: a description of the business processes and data, and the stakeholders to interview
  • Example: LLM01: assess where AI fits in our company and rank the use cases

🔥 LLM02 | Design a local inference system: models, hardware, serving, scaling and limits
  • ID: pmt-45641386
  • Scope: repo | Mode: write
  • Needs: the chosen use case (AIS01), data sensitivity, available hardware and latency targets
  • Example: LLM02: design the on-premises inference service for the support use case

🔥 LLM03 | Connect inference to business applications and production systems safely
  • ID: pmt-692f03a1
  • Scope: repo | Mode: write
  • Needs: the inference service (AIS02), the API or database of the target application and an agreed owner
  • Example: LLM03: connect the local model to the ERP and the production line dashboard

🔥 LLM04 | Build a local-AI chatbot to embed in an existing website
  • ID: pmt-22aecc7c
  • Scope: repo | Mode: write
  • Needs: the existing site and its stack, a local model endpoint (AIS02), the knowledge sources and the tone of voice
  • Example: LLM04: add a local-AI chatbot widget to our existing website

🔥 LLM05 | Design retrieval (RAG) over company documents with access control and evals
  • ID: pmt-61a987a2
  • Scope: repo | Mode: write
  • Needs: the document sources, their permissions and a set of real questions to answer
  • Example: LLM05: design retrieval over the company manuals and test it on real questions

🔥 LLM06 | Operate an AI system in production with evaluation and monitoring
  • ID: pmt-866ddd80
  • Scope: repo | Mode: write
  • Needs: a running AI feature, a representative evaluation set and access to its logs
  • Example: LLM06: set up evaluation, monitoring and a rollback plan for the chatbot

🔭 LLM07 | Assess AI privacy, security and compliance (GDPR, AI Act, prompt injection)
  • ID: pmt-df63e53f
  • Scope: repo | Mode: read
  • Needs: the AI system design, the data it processes and the jurisdiction
  • Example: LLM07: assess privacy, security and compliance risks of the company chatbot

🔭 LLM08 | Estimate the cost and ROI of company AI with an adoption plan
  • ID: pmt-6c6771d0
  • Scope: repo | Mode: read
  • Needs: the ranked use cases (AIS01), expected volumes and the current process cost
  • Example: LLM08: estimate cost and return of the chatbot and plan staff adoption

🔥 LLM09 | Automate a business process with AI agents, tools and human review
  • ID: pmt-9f755f33
  • Scope: repo | Mode: write
  • Needs: a documented process, the systems it touches and the people who approve exceptions
  • Example: LLM09: automate invoice triage with an AI agent and human approval


== CENTRAL SECONDBRAIN: RUN FROM THE SECONDBRAIN CHECKOUT ==

SB SYSTEM: DOSSIER, SOURCES AND ENTITIES
🔥 KNW02 | Compact the dossier preserving originals, facts and TOC
  • ID: pmt-77d7bf7a
  • Scope: central | Mode: write
  • Needs: dossier to compact and verifiable history
  • Example: sb prompt KNW02: compact the dossier history preserving facts and toc

🔥 KNW03 | Manage projects, areas and resources of the central PARA
  • ID: pmt-4e1b7c52
  • Scope: central | Mode: write
  • Needs: goal of the PARA entity and a write session on the SecondBrain clone
  • Example: sb prompt KNW03: archive the finished resource res-guida

✅ KNW04 | Check the authoritative source registry and its metadata
  • ID: pmt-5b593404
  • Scope: central | Mode: verify
  • Needs: the registry resource and the scope to check
  • Example: check the registry before the release

🔥 KNW05 | Collect authoritative sources and rebuild the source views
  • ID: pmt-6800e67e
  • Scope: central | Mode: write
  • Needs: the registry and the user decision on each candidate
  • Example: update the sources flagged as stale


SB SYSTEM: WORKSTATION, IDES AND MCP
🔥 WKS01 | Guide the first-run setup of SecondBrain, IDE, agent, directives and MCP
  • ID: pmt-a17c3e52
  • Scope: central | Mode: write
  • Needs: fresh SecondBrain checkout, one supported IDE and confirmation before each write
  • Example: sb setup: configure this clean workstation with vscode

🔥 WKS02 | Activate SecondBrain after discovery and asset selection
  • ID: pmt-5f9f93e0
  • Scope: central | Mode: write
  • Needs: SecondBrain volume and user consent on the assets
  • Example: sb prompt WKS02: activate secondbrain selecting local repositories and ides

✅ WKS03 | Check the workstation assets against the approved associations
  • ID: pmt-677a10ab
  • Scope: central | Mode: verify
  • Needs: an activated workstation
  • Example: run sb check and explain the findings

🔥 WKS04 | Align IDE and workstation assets with the approved directive texts
  • ID: pmt-98daa4bf
  • Scope: central | Mode: write
  • Needs: approved directive texts and managed assets
  • Example: run sb sync and keep my conflicts

✅ WKS05 | Check the IDE instructions, profiles and loading receipts
  • ID: pmt-26817a61
  • Scope: central | Mode: verify
  • Needs: an activated workstation and its IDE map
  • Example: check which IDEs load the current directives

🔥 WKS06 | Register an IDE account or root and record an observation receipt
  • ID: pmt-b6d9f6f4
  • Scope: central | Mode: write
  • Needs: an activated workstation and the account details the user declares
  • Example: register my second Claude account with the alias work

🔥 WKS07 | Install the SecondBrain MCP server in the IDEs and verify the handshake
  • ID: pmt-2d3c1d51
  • Scope: central | Mode: write
  • Needs: SecondBrain root, target IDEs and confirmation before writing
  • Example: sb prompt WKS07: install the mcp server in vscode and claude code

🔥 WKS08 | Install or update the skills selected after a project analysis
  • ID: pmt-3d7b91c4
  • Scope: central | Mode: write
  • Needs: a project checkout, the agents and scope to install into, and confirmation before each write
  • Example: sb skills: analyze this project and install the useful skills for claude-code and codex

🔥 WKS09 | Run the deterministic compressed backup and verify the SHA-256 digests
  • ID: pmt-e498353a
  • Scope: central | Mode: write
  • Needs: active configuration and backup runtime root
  • Example: sb prompt WKS09: run a deterministic backup and validate the sha-256 manifest


SB SYSTEM: CATALOG, DIRECTIVES AND SKILLS
🔥 DIR01 | Maintain a prompt card or preset of the catalog
  • ID: pmt-364616bb
  • Scope: central | Mode: write
  • Needs: the card or preset to add, change or retire
  • Example: add a card for reviewing database migrations

🔥 DIR03 | Update a skill from authoritative sources and verify the diff
  • ID: pmt-9ef61b3d
  • Scope: central | Mode: write
  • Needs: identified skill, target agent and version, official sources
  • Example: sb prompt DIR03: update the local skill from official sources


SB SYSTEM: SECONDBRAIN UPKEEP
✅ UPK01 | Health check: directives, IDEs, prompts, tests and publication scan
  • ID: pmt-1456d6b9
  • Scope: central | Mode: verify
  • Needs: the SecondBrain checkout, PowerShell 7.5+ and Git
  • Example: UPK01: run the health check and report what drifted

✅ UPK02 | Verify backups with a real restore test and report coverage gaps
  • ID: pmt-03822742
  • Scope: central | Mode: verify
  • Needs: the backup archives, the manifest and an empty scratch folder for the restore
  • Example: UPK02: test the latest backup by restoring it into a scratch folder

⛔ UPK03 | Review .runtime and clean up in preview; apply only with authorization
  • ID: pmt-ba610991
  • Scope: central | Mode: write
  • Needs: the checkout, no active sessions and the owner's authorization before any deletion
  • Example: UPK03: report what .runtime holds and propose the cleanup preview

🔥 UPK04 | Refresh authoritative sources, skills and tool versions and verify the diff
  • ID: pmt-0fdd6f29
  • Scope: central | Mode: write
  • Needs: network access to official sources and the registered sources and skills of the workstation
  • Example: UPK04: check the registered sources and skills for updates

🔥 UPK05 | Prepare a directive revision: proposal, preview, version, changelog, checks
  • ID: pmt-fd98d7ce
  • Scope: central | Mode: write
  • Needs: a concrete change to the common directives and the owner's approval path
  • Example: UPK05: prepare the revision proposal for the new common directive

```
