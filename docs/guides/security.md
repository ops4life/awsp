---
title: Security
description: Security policy and practices for awsp
---

# Security

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly. **Do not publicly disclose security vulnerabilities.**

### How to Report

1. **GitHub Security Advisories** (Recommended)
    - Navigate to the "Security" tab of the repository
    - Click "Report a vulnerability"
    - Fill out the vulnerability report form

2. **Email**
    - Contact the maintainers via email
    - Include a detailed description and reproduction steps

### What to Include

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact assessment
- Suggested fixes (if available)
- Your contact information for follow-up

## Security Measures

### Automated Scanning

| Tool | Purpose |
|---|---|
| **Gitleaks** | Secret scanning in pre-commit hooks and CI/CD |
| **Dependabot** | Automated dependency vulnerability updates |
| **Dependency Review** | Supply chain security analysis on pull requests |
| **CodeQL** | Static analysis for code vulnerabilities |

### Development Security

- **Pre-commit hooks** run automated security checks before every commit
- **Branch protection** requires reviews and passing status checks on `main`
- **Conventional Commits** enforce structured commit messages
- **Signed commits** are encouraged for all contributors

## Security Update Process

1. **Assessment** — Reported vulnerabilities are assessed within 48 hours
2. **Fix Development** — Critical vulnerabilities are prioritized immediately
3. **Testing** — All security fixes are thoroughly tested
4. **Release** — Security updates are released as patch versions
5. **Disclosure** — Public disclosure occurs after the fix is released

## Best Practices for Users

When using awsp:

1. **Install pre-commit hooks** — Run `pre-commit install` immediately after cloning
2. **Keep awsp updated** — Run `awsp --upgrade` regularly
3. **Review AWS credentials** — Never commit AWS credentials to version control
4. **Use SSO profiles** — Prefer SSO-based authentication over static credentials
5. **Rotate credentials** — If credentials are accidentally exposed, rotate them immediately
6. **Enable MFA** — Use multi-factor authentication on your AWS accounts

## Responsible Disclosure

We ask security researchers to:

- Give us reasonable time to respond before public disclosure
- Avoid privacy violations, data destruction, or service disruption
- Act in good faith
