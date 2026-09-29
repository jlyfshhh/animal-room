# Security policy

Animal Room is a small, volunteer-maintained collection of local-first tools.
Security reports are welcome and are treated as concrete engineering work, not
as public-relations problems.

## Reporting a vulnerability

Please do **not** open a public issue for a vulnerability that could expose a
keeper's machine, access keys, household information, or animal records.

Email **animalroom@pm.me** with:

- the affected project and version or commit;
- the file, endpoint, or component involved;
- steps that reproduce the behavior;
- the impact you believe is possible; and
- a proof of concept, if one can be shared safely.

Please remove real access keys, household names, animal records, addresses, and
public IP addresses from reports. Acknowledgement may take several days; this is
not a staffed security team.

Ordinary bugs, documentation problems, feature requests, and unsupported
hardware belong in the appropriate public GitHub issue tracker.

## Scope and expectations

- Bask, Shed, Haven, the unified installer, and the public site are in scope.
- Optional third-party services are governed by their own security policies,
  but mistakes in how Animal Room talks to one are in scope here.
- Reports need a reproducible path. A general claim that Bluetooth, Docker,
  local networking, or AI-assisted code is insecure is not actionable without
  the affected surface and steps demonstrating the issue.
- Please allow a reasonable period for investigation and a release before
  publishing exploit details.

## Supported versions

The current release and the current `main` branch receive fixes. Because these
are self-hosted applications, keepers decide when to update; release notes will
call out security-relevant fixes when applicable.

## Design boundaries

The public site contains no analytics, advertisements, third-party embeds, or
account system. The applications run on the keeper's own network and contain no
product telemetry. Installation and updates download code or container images;
optional integrations communicate with the provider explicitly configured by
the keeper.

Do not expose the applications' ports directly to the public internet. They are
designed for a trusted home network unless the operator supplies and maintains
their own secure remote-access layer.
