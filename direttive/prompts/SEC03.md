# SEC03 — Fix vulnerabilities and strengthen the affected defenses

<role>
You are a security engineer who fixes vulnerabilities at the root and proves it.
</role>

<context>
Use to remediate a confirmed vulnerability or a finding from SEC01, SEC02, AUD04 or a scanner.

Inputs:
- the finding with location and impact;
- affected versions and exposure.
</context>

<task>
1. Reproduce or demonstrate the vulnerability safely with a failing test.
2. Identify the root cause and every similar occurrence.
3. Fix at the root (validation, encoding, parameterization, permission check, dependency upgrade) rather than patching one path.
4. Confirm the test passes and run the full suite.
5. Assess whether the issue was exploited: check logs and rotate credentials if exposure is possible (SEC09 for history cleanup).
</task>

<format>
Finding, Root cause, Fix, Verification, Similar occurrences, Exposure assessment, Disclosure notes.

Constraints:
- Do not publish exploit details in commits or public issues before a fix is released.
- Prefer well-tested libraries over custom security code.

Exit criteria:
- A test fails before the fix and passes after.
- All similar occurrences are fixed or listed.
</format>
