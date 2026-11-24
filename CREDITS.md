# Credits and Third-Party Attributions

This document acknowledges the open-source projects, standards, toolchains and methodological references that support the architecture and operation of **SecondBrain**.

---

## 1. Toolchain and Runtime

### PowerShell 7 (PowerShell Core)
- **Author / Maintainer**: Microsoft Corporation and the PowerShell Team
- **License**: [MIT License](https://github.com/PowerShell/PowerShell/blob/master/LICENSE.txt)
- **Description**: Modern, cross-platform and deterministic automation engine and scripting language for Windows, Linux and macOS.

### Git Version Control System
- **Author**: Linus Torvalds, Junio C Hamano and Git contributors
- **License**: GNU General Public License v2 (GPL-2.0)
- **Description**: The standard distributed version control system used to track changes and coordinate repositories and workstations deterministically.

### MarkItDown

The optional source converter uses MarkItDown 0.1.9, developed by Microsoft and distributed under the MIT license. The `pdf` and `docx` extras enable converting those formats to Markdown. [Release 0.1.9](https://pypi.org/project/markitdown/0.1.9/) · [Upstream license](https://github.com/microsoft/markitdown/blob/main/LICENSE)

The [manifest](scripts/source-requirements.txt) declares `markitdown[pdf,docx]==0.1.9`. The [lock](scripts/source-requirements.lock.txt) pins the versions of 30 packages, including the converter, with the sha256 hashes required by `pip --require-hashes`. The dedicated Python 3.13 environment lives in the `sources/python` subfolder of the workstation runtime. The packages are installed locally and stay outside product builds and the SecondBrain distribution. [Converter configuration](docs/reference/authoritative-sources.md)

### Desktop orchestrator (`app/orchestrator`)

The repository contains the app source and the dependency locks; no binary or installer is distributed: the app is built on the workstation with `npm ci` and `cargo`. Versions come from the locks and licenses from the package metadata (installed `package.json` files, `cargo metadata`) of 2026-11-12, rechecked against the locks on 2026-11-14 (versions and counts unchanged); component versions updated on 2026-11-24 after the Dependabot merges (package counts and license tallies below were not recomputed). The project is MIT (`LICENSE` file, declared in `package.json` and `Cargo.toml`).

| Component | Version | License (SPDX) | Role | Source |
| --- | --- | --- | --- | --- |
| Tauri (`tauri`, `tauri-build`) | 2.12.7, 2.7.6 | Apache-2.0 OR MIT | App runtime and build | [tauri-apps/tauri](https://github.com/tauri-apps/tauri) |
| `tauri-plugin-dialog` | 2.8.4 | Apache-2.0 OR MIT | File and folder pickers | [tauri-apps/plugins-workspace](https://github.com/tauri-apps/plugins-workspace) |
| `serde`, `serde_json` | 1.0.229, 1.0.154 | MIT OR Apache-2.0 | Serialization | [serde-rs](https://github.com/serde-rs) |
| `@tauri-apps/api`, `@tauri-apps/plugin-dialog` | 2.12.5, 2.8.4 | Apache-2.0 OR MIT | TypeScript interface | [tauri-apps](https://github.com/tauri-apps) |
| Vite | 8.3.8 | MIT | Development only: frontend build | [vitejs/vite](https://github.com/vitejs/vite) |
| TypeScript | 7.0.2 | Apache-2.0 | Development only: compiler | [microsoft/TypeScript](https://github.com/microsoft/TypeScript) |
| Playwright (`@playwright/test`) | 1.65.1 | Apache-2.0 | Development only: end-to-end tests | [microsoft/playwright](https://github.com/microsoft/playwright) |
| Tauri CLI (`@tauri-apps/cli`) | 2.12.6 | Apache-2.0 OR MIT | Development only: app build | [tauri-apps/tauri](https://github.com/tauri-apps/tauri) |

Transitive dependencies: 423 Rust crates in the lock (all platforms) with permissive licenses, except 7 MPL-2.0 crates (`cssparser`, `cssparser-macros`, `selectors`, `dtoa-short`, `option-ext`; weak file-level copyleft) and 18 Unicode-3.0 crates (the ICU4X family, a permissive license with a notice); `r-efi` also offers LGPL-2.1-or-later as an alternative to MIT and Apache-2.0. The 82 npm packages in the lock are permissive (MIT, ISC, Apache-2.0, BSD-3-Clause); the 60 optional binaries for other platforms from esbuild, Rollup and Tauri CLI are not installed here and their license was not read. If an app binary is distributed, the license notices of the included dependencies, the source indication for the MPL-2.0 files and the Unicode-3.0 notice must be attached.

App icons (`app/orchestrator/src-tauri/icons/`): the origin of the original icons (commit 2e6d84b) was neither documented nor reconstructable from the repository, so their license could not be verified and they were replaced on 2026-11-17. The current icons are an original design of the project (three queue bars with a start node), produced by `app/orchestrator/icon-source/make-icon.py` (Pillow, no third-party artwork) and converted to the required formats with `tauri icon` (Tauri CLI, Apache-2.0 OR MIT). License: MIT, like the rest of the repository (`LICENSE`). Reproducible source: `app/orchestrator/icon-source/icon-source.png`.

---

## 2. Standards and Technical Specifications

### JSON Schema (Draft 2020-12)
- **Organization**: Internet Engineering Task Force (IETF) / JSON Schema Community
- **Website**: [json-schema.org](https://json-schema.org/)
- **Description**: Specification for declaratively validating the structure and data contracts of configuration files, prompt catalogs and trackers.

### SPDX (Software Package Data Exchange)
- **Organization**: Linux Foundation
- **License**: Creative Commons Attribution License 3.0 (CC-BY-3.0)
- **Website**: [spdx.dev](https://spdx.dev/)
- **Description**: International standard (ISO/IEC 5962:2021) for accurately communicating software license and intellectual-property information.

### OWASP Top 10
- **Organization**: OWASP Foundation
- **License**: Creative Commons Attribution Share-Alike 4.0 (CC-BY-SA 4.0)
- **Website**: [owasp.org](https://owasp.org/)
- **Description**: Consensus document and awareness standard on the main security vulnerabilities and code-hardening practices.

---

## 3. Methodological References

### PARA method (Projects, Areas, Resources, Archives)
- **Author**: Tiago Forte / Forte Labs
- **Reference**: *Building a Second Brain* (2022)
- **Description**: Conceptual taxonomy adopted by SecondBrain to organize knowledge, ongoing responsibilities and project memory without dispersion.

### Prompt-engineering guides and specifications for coding agents
- **Anthropic**: [Claude Prompt Library & Common Workflows](https://code.claude.com/docs/en/prompt-library)
- **OpenAI**: [OpenAI Prompt Engineering Guides](https://developers.openai.com/api/docs/guides/prompt-engineering)
- **Google DeepMind / Antigravity**: Guidelines for deterministic prompt engineering and agentic architecture for pair programming.
- **Anthropic**: [Prompt engineering overview](https://docs.claude.com/en/docs/build-with-claude/prompt-engineering/overview) (role, XML tags, explicit output format) and [Claude Code memory](https://code.claude.com/docs/en/memory) (`CLAUDE.md` and the `@AGENTS.md` import).
- **Google**: [Prompt design strategies](https://ai.google.dev/gemini-api/docs/prompting-strategies).
- **AGENTS.md**: [agents.md](https://agents.md), the open format for coding-agent instructions.
- **CO-STAR**: prompt-structure framework (Context, Objective, Style, Tone, Audience, Response) from the GovTech Singapore competition.

---

## 4. Third-party texts in the source registry

Since #478, `shared/authoritative-sources/entries/*/versions/` contains Markdown transcripts of sources with `rights.status` `public-reusable`: format conversions of the originals, which stay local (`versions/*/originals/` is excluded from Git). Files are identified by hash and are not edited; the notices required by the licenses are collected here. Conditions were read from the publishers' pages on 2026-11-12.

| Source (entry) | Rights holder | Terms | Obligations for the copies in the repository |
| --- | --- | --- | --- |
| OWASP ASVS 5.0.0 (`owasp-asvs`) | OWASP ASVS contributors | [CC-BY-SA-4.0](https://github.com/OWASP/ASVS/blob/master/LICENSE.md) | Attribution, link to the license, indication of changes (conversion to Markdown); derived transcripts remain CC-BY-SA-4.0 |
| OWASP Cheat Sheet Series: Password Storage, File Upload (`owasp-password-storage`, `owasp-file-upload`) | OWASP Cheat Sheet Series contributors | [CC-BY-SA-4.0](https://github.com/OWASP/CheatSheetSeries/blob/master/LICENSE.md) | As above |
| WCAG 2.2 (`w3c-wcag`) | World Wide Web Consortium | [W3C Document License 2023](https://www.w3.org/copyright/document-license-2023/) | Link to the original, copyright notice and STATUS section kept; the transcript is not presented as a technical specification |
| NIST SP 800-63B-4, SP 800-218 (`nist-digital-identity`, `nist-ssdf`) | National Institute of Standards and Technology | [NIST Open License](https://www.nist.gov/open/license): works of federal employees are not subject to copyright in the US (17 U.S.C. §105) | Cite NIST and the authors; outside the US, reserved rights may apply |
| EFF Large Wordlist (`eff-diceware`) | Electronic Frontier Foundation | [EFF site policy](https://www.eff.org/copyright): original material CC-BY-4.0 | Attribution to EFF; the wordlist page names no license of its own (to be verified) |
| AI Act, GDPR and consolidated texts, Regulation (EU) 2026/1744 (`eu-ai-act`, `eu-gdpr`, `eu-gdpr-consolidation`, `eu-ai-omnibus-2026`) | European Union | [EUR-Lex legal notice](https://eur-lex.europa.eu/content/legal-notice/legal-notice.html), Decision 2011/833/EU | Cite the source; the Official Journal is authentic. The EUR-Lex page was unreadable on 2026-11-12 (empty response): conditions to be rechecked |
| Commission AI framework (`ec-ai-framework`) | European Commission | [Legal notice](https://commission.europa.eu/legal-notice_en): CC-BY-4.0 unless stated otherwise | Attribution "© European Union", indication of changes; third-party content and logos excluded |
| EDPB legal framework (`edpb-legal-framework`) | European Data Protection Board | [EDPB copyright](https://www.edpb.europa.eu/copyright_en): reuse allowed, including commercial | Cite the source, do not distort the meaning, keep author and source indications unchanged |
| Law 132/2025, Legislative Decrees 151/2015 and 185/2016 (`it-ai-law-132-2025`, `it-dlgs-151-2015`, `it-dlgs-185-2016`) | Italian Republic (Gazzetta Ufficiale) | [Art. 5 of Law 633/1941](https://www.normattiva.it/uri-res/N2Ls?urn:nir:stato:legge:1941-04-22;633~art5): the copyright law does not apply to official acts | Cite the source; the Gazzetta Ufficiale issues also contain other acts, kept as context |

Notice required by the W3C Document License: Copyright © 2020-2024 World Wide Web Consortium. W3C®. This software or document includes material copied from or derived from Web Content Accessibility Guidelines (WCAG) 2.2, https://www.w3.org/TR/WCAG22/.

## 5. Legal Notes

All registered trademarks, logos and trade names mentioned in this repository belong to their respective owners. **SecondBrain** is distributed under the [MIT](LICENSE) license.

### Compatibility with the project's MIT license

| Component | License | Use in SecondBrain | Outcome |
| --- | --- | --- | --- |
| PowerShell 7 | MIT | Required runtime, not redistributed | Compatible |
| Git | GPL-2.0 | External tool invoked from the command line, neither embedded nor redistributed | Compatible (no derivative work) |
| MarkItDown 0.1.9 | MIT | Optional direct dependency for source conversion, installed in the runtime | License of the direct package |
| Tauri, serde and the orchestrator dependencies | Apache-2.0 OR MIT; transitive with MPL-2.0 and Unicode-3.0 | Source and lock in the repository, built locally; no binary distributed | Permissive licenses; notice obligations only if a binary is distributed |
| Source-registry transcripts | CC-BY-SA-4.0, W3C Document License, CC-BY-4.0, EDPB and NIST terms, official acts | Texts included in the repository (§4) | Their own licenses, not covered by the MIT license; notices in §4 |
| JSON Schema, SPDX, PARA | Specifications and references | Cited in the documentation, no code embedded | Compatible |

The MIT license covers SecondBrain's code and original texts; the third-party texts in §4 stay under their own terms. For the packages in the Python lock, the licenses and notices of the respective projects apply. The inventory of versions is in the lock. Optional tools used locally for captures stay outside the distribution.
