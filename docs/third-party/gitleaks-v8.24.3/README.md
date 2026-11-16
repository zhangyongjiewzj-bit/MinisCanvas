# Gitleaks rule data

Upstream: https://github.com/gitleaks/gitleaks
Pinned release: v8.24.3 (release commit 107a41827bb6698dbbff756b2300537774a1d84c)
Source: https://raw.githubusercontent.com/gitleaks/gitleaks/v8.24.3/config/gitleaks.toml
Source SHA-256: 8f393899dbdc67e4eae580909e496acab9cf3a75aacfb6fac56b6eb16bb9e051
License: MIT, Copyright (c) 2019 Zachary Rice. Full license is retained in LICENSE.

Only selected format rules are used, as data; no upstream scanner code is included. selected-rules.json retains their upstream records. GitleaksSecretRules.swift embeds the selected regexes into the resource-free Core target without changing their regex syntax, and masks the first capture (or the whole match when no capture is defined) with the existing app masking function. This is format redaction, not the full Gitleaks entropy/allowlist scanner. Existing assignment/header and known-value redaction still applies.
