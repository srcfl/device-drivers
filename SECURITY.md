# Security

Do not report a vulnerability in a public issue. Use GitHub's private security
advisory flow for this repository.

Never include credentials, signing material, private addresses, device serial
numbers or site telemetry in an issue, pull request, fixture or log.

Pull-request builds are unsigned. Only the release workflow on `main` signs
FTW's driver channel, with credentials held as GitHub Actions secrets.
