# Contributing to SUNK Anywhere

## Contributions

SUNK is one of the leading solutions for running Slurm on Kubernetes. It powers
workloads across hundreds of thousands of NVIDIA GPUs and is the orchestrator
of choice for customers running AI research and production. SUNK Anywhere
extends SUNK to run on providers beyond CoreWeave.

Contribute here to improve the experience of running SUNK Anywhere on other
cloud providers: implement provider-specific integrations, fix bugs, integrate
it with open-source and third-party tooling, and improve performance.

## Contributors Licence Agreement - CLA

We ask that you agree to the [CoreWeave CLA](./CLA.md) when pushing code to this project.

Agreement with the CoreWeave CLA is signified by including a `Signed-Off-By`
trailer in every Git commit to this repository. This can be done by using the
`--signoff` option to [`git
commit`](https://git-scm.com/docs/git-commit#Documentation/git-commit.txt---signoff).

## License headers
<!--- REUSE-IgnoreStart -->

Source code should contain an SPDX-style license header, reflecting:
- Year & Copyright owner
- SPDX License identifier `SPDX-License-Identifier: Apache-2.0`
- Package Name: `SPDX-PackageName: sunk-anywhere`

This can be partially automated with [FSFe REUSE](https://reuse.software/dev/#tool)
```shell
reuse annotate --license Apache-2.0 --copyright 'CoreWeave, Inc.'  --year 2026 --template default_template --skip-existing $FILE
```

Blindly adding the headers to every file without review risks assigning the
wrong copyright owner! You should endeavor to understand who owns
contributions!

- This repository is licensed under the Apache-2.0 license to protect the
  rights of all parties.

Licensing state & SPDX bill-of-materials (BOM) can be validated & generated with:
```shell
reuse lint
reuse spdx
```

<!--- REUSE-IgnoreEnd -->
