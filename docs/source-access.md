# Source Access and Redistribution

This page explains the source and redistribution boundary that starts with the
`v1.0.0` release line.

## Public distribution

Starting with `v1.0.0`, the public winsmux distribution is the released product,
not a full implementation source drop. The public release surface includes:

- the Windows desktop installer
- the MSI deployment artifact
- the npm package and CLI installer path
- checksum files
- release notes
- user and contributor-facing public documentation
- public issue discussion for bugs, support, and feature requests

The public repository can keep documentation, release metadata, examples,
security policy, and compatibility notes, but it is no longer the place where
all implementation source is published.

## Paid-member source community

Selected implementation source can be shared with Substack paid members for
review, learning, and improvement proposals. That access is a member community
program, not an open redistribution grant.

The member source program follows these rules:

- source snapshots are selected by the maintainer
- secrets, local paths, credentials, private prompts, and release keys are
  removed before sharing
- redistribution, mirroring, and republishing are not permitted
- access can use a private repository, member-only download, or another
  member-only channel chosen by the maintainer
- access is revoked when membership or the review program ends
- contributions are handled as proposals or patches that require maintainer
  acceptance before they affect public releases
- public issue comments and public documentation must not quote member-only
  source unless the maintainer has already published that source publicly

## Boundary

Public users can install, update, verify, and report issues without source
access. Paid-member source access is for review and community contribution only.
It does not grant rights to redistribute winsmux or create a competing public
source mirror.

Security reports should use the public security policy. Do not send secrets or
private customer data through a member discussion channel.
