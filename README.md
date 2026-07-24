<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🔧 Maven XML Settings Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/maven-xml-settings-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/maven-xml-settings-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/maven-xml-settings-action)
<!-- prettier-ignore-end -->

Generate a Maven `settings.xml` from workflow parameters and expose it as
both an output string and an on-disk file.

The action removes the need to embed a bespoke `settings.xml` heredoc in
every workflow. It pairs naturally with
[`maven-build-action`](https://github.com/lfreleng-actions/maven-build-action):
feed the `settings-content` output into that action's `global-settings`
input.

## Usage

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: "Generate Maven settings"
    id: settings
    uses: lfreleng-actions/maven-xml-settings-action@main
    with:
      server-ids: "central-releases, central-snapshots"
      username: ${{ vars.NEXUS_USERNAME }}
      password: ${{ secrets.NEXUS_PASSWORD }}
      mirror-id: "public"
      mirror-url: "https://nexus.example.org/content/groups/public/"

  - name: "Build with Maven"
    uses: lfreleng-actions/maven-build-action@main
    with:
      global-settings: ${{ steps.settings.outputs.settings-content }}
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                   | Required | Default | Description                     |
| ---------------------- | -------- | ------- | ------------------------------- |
| server-ids             | True     |         | Maven server `<id>` values      |
|                        |          |         | sharing the credentials         |
|                        |          |         | (comma, space or newline        |
|                        |          |         | separated)                      |
| username               | True     |         | Username applied to every       |
|                        |          |         | listed server                   |
| password               | True     |         | Password applied to every       |
|                        |          |         | listed server                   |
| mirror-id              | False    | ""      | Mirror `<id>`; requires         |
|                        |          |         | mirror-url to take effect       |
| mirror-url             | False    | ""      | Mirror `<url>`; requires        |
|                        |          |         | mirror-id to take effect        |
| mirror-of              | False    | "*"     | Mirror `<mirrorOf>` selector    |
|                        |          |         | (applies when setting a mirror) |
| profile-id             | False    | ""      | Active profile `<id>`; requires |
|                        |          |         | profile-repository-url          |
| profile-repository-url | False    | ""      | Repository URL for the active   |
|                        |          |         | profile; requires profile-id    |
| settings-path          | False    | ""      | Path to write settings.xml to   |
|                        |          |         | (defaults under RUNNER_TEMP)    |

<!-- markdownlint-enable MD013 -->

Supply the server IDs that share credentials as a single list; each
becomes a `<server>` entry with the given `username`/`password`. The
mirror and profile blocks render when you set both of their required
fields.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name             | Description                                       |
| ---------------- | ------------------------------------------------- |
| settings-content | The generated `settings.xml` content              |
| settings-path    | Path the action writes the `settings.xml` to      |

<!-- markdownlint-enable MD013 -->

## Implementation Details

- The action registers the `password` with `::add-mask::` to keep it out
  of workflow logs.
- The action XML-escapes element text (IDs, username, password, URLs),
  so values containing `&`, `<` or `>` cannot corrupt the document or
  inject stray elements.
- A randomised heredoc delimiter wraps the `settings-content` output, and
  the action regenerates that delimiter until the generated XML no longer
  contains it, so the content cannot close the output block prematurely.

## Example: ONAP Nexus

The following reproduces the five-server ONAP Nexus layout (all servers
share the project credentials) together with the public mirror and the
`onap-public` profile:

<!-- markdownlint-disable MD046 -->

```yaml
- name: "Generate ONAP Maven settings"
  id: onap-settings
  uses: lfreleng-actions/maven-xml-settings-action@main
  with:
    server-ids: |
      ecomp-releases
      ecomp-snapshots
      onap-releases
      onap-snapshots
      nexus3.onap.org:10003
    username: ${{ steps.extract-project.outputs.project-name }}
    password: ${{ env.NEXUS_V2_PASSWORD }}
    mirror-id: "onap-public"
    mirror-url: "https://nexus.onap.org/content/groups/public/"
    profile-id: "onap-public"
    profile-repository-url: "https://nexus.onap.org/content/groups/public/"
```

<!-- markdownlint-enable MD046 -->

## Notes

The action performs no network access and renders XML from its inputs
alone. Pair it with a build action (for example `maven-build-action`)
that consumes the generated settings through its `global-settings`
input.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/maven-xml-settings-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/maven-xml-settings-action/main.svg
