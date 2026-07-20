# Source import

The initial public tree was reviewed and imported from the private
`srcfl/srcful-device-support` repository at commit
`5b16f74fc64321aedf09044622dfe05b3155a5e4`.

The import includes driver source, public manifests, public contracts, package
recipes, tests and local validation tools. It excludes the service API,
database, admin UI, deployment, cloud release code and signing material.

From this import onward, this public repository is the editable source. The
private service consumes a locked commit and must reject local source drift.
