# Security Policy

## Security maintainer

SpotOn is maintained by **Marek Stiefenhofer** ([@stiefenm](https://github.com/stiefenm)),
who also acts as the project's **security maintainer** and single point of contact for
security matters. All vulnerability reports are triaged, coordinated, and disclosed by the
maintainer.

## Supported versions

Security fixes are provided for the latest released version of SpotOn. Users are expected to
run a current release, installed via the SpotOn plugin repository in Lyrion Music Server.

| Version            | Supported          |
| ------------------ | ------------------ |
| Latest release     | :white_check_mark: |
| Older releases     | :x:                |

## Reporting a vulnerability

Please report security issues **privately**. Do not open a public issue for a suspected
vulnerability.

Channel:

- **GitHub Security Advisories**: open a private report via the repository's
  **Security → Report a vulnerability** page:
  <https://github.com/stiefenm/spoton/security/advisories/new>

When reporting, please include:

- affected SpotOn version and backend (librespot or Soloist),
- platform and LMS version,
- a description of the issue and its impact,
- steps to reproduce, and a proof of concept where possible.

## Response process

- The maintainer aims to acknowledge a report within **5 business days**.
- Confirmed vulnerabilities are fixed in a new release; a GitHub Security Advisory is
  published once a fix is available.
- Reporters are credited in the advisory unless they ask to remain anonymous.

## Security-relevant scope

SpotOn handles security-sensitive functionality, including:

- **Account credentials and tokens**: pairing with and authenticating against Spotify
  using the login of the user's paired account; credentials and tokens are stored locally
  and are not transmitted to any third party by SpotOn.
- **Third-party binaries**: download, renewal, and execution of audio-client binaries
  (librespot shipped with SpotOn; Soloist downloaded from Spotify's own download page on the
  user's LMS host). Binary integrity and the update/rollback flow are in scope.
- **Local process and IPC handling**: the librespot process, Spotify Connect (Spirc) sync,
  and the `spoton://` protocol handler.

## Out of scope

- Vulnerabilities in Spotify's own services, clients, or in the Soloist binary itself.
- Vulnerabilities in Lyrion Music Server or in unrelated third-party plugins.
- Issues that require a pre-compromised LMS host or physical access.
